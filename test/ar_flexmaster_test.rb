# frozen_string_literal: true
require 'bundler/setup'
require 'ar_mysql_flexmaster'
require 'active_record'
require 'minitest/autorun'
require 'mocha/mini_test'
require 'logger'

if !defined?(Minitest::Test)
  Minitest::Test = MiniTest::Unit::TestCase
end

require_relative 'boot_mysql_env'

ActiveRecord::Base.configurations = YAML.load_file(__dir__ + '/database.yml')
ActiveRecord::Base.establish_connection(:test)

class User < ActiveRecord::Base
end

class UserSlave < ActiveRecord::Base
  establish_connection(:test_slave)
  self.table_name = "users"
end

class Reconnect < ActiveRecord::Base
  establish_connection(:reconnect)
  self.table_name = "users"
end

class ReconnectSlave < ActiveRecord::Base
  establish_connection(:reconnect_slave)
  self.table_name = "users"
end

class TestArFlexmaster < Minitest::Test
  def setup
    ActiveRecord::Base.establish_connection(:test)

    $mysql_master.set_rw! if $mysql_master
    $mysql_slave.set_ro! if $mysql_slave
    $mysql_slave_2.set_ro! if $mysql_slave_2
  end

  def test_should_raise_without_a_rw_master
    [$mysql_master, $mysql_slave].each do |m|
      m.set_ro!
    end

    e = assert_raises(ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter::NoServerAvailableException) do
      ActiveRecord::Base.connection
    end

    assert e.message =~ /NoActiveMasterException/
  end

  def test_should_select_the_master_on_boot
    assert_equal $mysql_master, master_connection
  end

  def test_should_hold_txs_until_timeout_then_abort
    ActiveRecord::Base.connection

    $mysql_master.set_ro!
    start_time = Time.now.to_i
    assert_raises(ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter::NoServerAvailableException) do
      User.create(:name => "foo")
    end
    end_time = Time.now.to_i
    assert end_time - start_time >= 5
  end

  def test_should_hold_txs_and_then_continue
    ActiveRecord::Base.connection
    $mysql_master.set_ro!
    Thread.new do
      sleep 1
      $mysql_slave.set_rw!
    end
    User.create(:name => "foo")
    assert_equal $mysql_slave, master_connection
    if ActiveRecord::VERSION::MAJOR >= 4
      assert User.where(:name => "foo").exists?
    else
      assert User.first(:conditions => { :name => "foo" })
    end
  end

  def test_should_hold_implicit_txs_and_then_continue
    User.create!(:name => "foo")
    $mysql_master.set_ro!
    Thread.new do
      sleep 1
      $mysql_slave.set_rw!
    end
    User.update_all(:name => "bar")

    assert_equal $mysql_slave, master_connection

    assert_equal "bar", User.first.name
  end

  def test_should_let_in_flight_txs_crash
    User.transaction do
      $mysql_master.set_ro!
      assert_raises(ActiveRecord::StatementInvalid) do
        User.update_all(:name => "bar")
      end
    end
  end

  def test_should_eventually_pick_up_new_master_on_selects
    ActiveRecord::Base.connection
    $mysql_master.set_ro!
    $mysql_slave.set_rw!
    assert_equal $mysql_master, master_connection
    100.times do
      User.first
    end
    assert_equal $mysql_slave, master_connection
  end

  # there's a small window in which the old master is read-only but the new slave hasn't come online yet.
  # Allow side-effect free statements to continue.
  def test_should_not_crash_selects_in_the_double_read_only_window
    ActiveRecord::Base.connection
    $mysql_master.set_ro!
    $mysql_slave.set_ro!
    assert_equal $mysql_master, master_connection
    100.times do
      User.first
    end
  end

  def test_should_expose_the_current_master_and_server_id
    cx = ActiveRecord::Base.connection
    assert_equal "dbs-1", cx.current_host
    assert_equal $mysql_master.server_id, server_id(cx)
  end

  def test_should_move_off_the_slave_after_it_becomes_master
    UserSlave.first
    User.create!
    $mysql_master.set_ro!
    $mysql_slave.set_rw!

    20.times do
      UserSlave.connection.execute("select 1")
    end

    assert [$mysql_master, $mysql_slave_2].include?(slave_connection)
  end

  def test_xxx_non_responsive_master
    return if ENV['TRAVIS'] # something different about 127.0.0.2 in travis, I guess.
    ActiveRecord::Base.configurations["test"]["hosts"] << "127.0.0.2:1235"
    start_time = Time.now.to_i
    User.connection.reconnect!
    assert Time.now.to_i - start_time >= 5, "only took #{Time.now.to_i - start_time} to timeout"
  ensure
    ActiveRecord::Base.configurations["test"]["hosts"].pop
  end

  def test_limping_along_with_a_slave_acting_as_a_master
    User.create!
    $mysql_master.down!

    # the test here is that even though we've asserted we want the master,
    # since we're doing a SELECT we'll stay limping along by running the SELECT on a slave instead.
    User.first

    assert [$mysql_slave, $mysql_slave_2].include?(master_connection)
  ensure
    $mysql_master.up!
  end

  def test_recovering_after_losing_connection_to_the_master
    User.create!
    assert User.connection.instance_variable_get("@connection")

    $mysql_master.down!
    # trying to do an INSERT with the master down puts is into a precious state --
    # we've got a nil @connection object.  There's two possible solutions here;
    #
    # 1 - substitute a slave connection in for the master object but raise an exception anyway
    # 2 - deal with a nil connection object later
    #
    # opting for (2) now
    #
    assert_raises(ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter::NoServerAvailableException) do
      User.create!
    end

    assert_equal nil, User.connection.instance_variable_get("@connection")

    # this proxies to @connection and has been the cause of some crashes
    assert User.connection.quote("foo")
  ensure
    $mysql_master.up!
  end

  def test_quote_string_should_recover_connection
    User.create!
    assert User.connection.instance_variable_get("@connection")
    User.connection.instance_variable_set("@connection", nil)

    assert User.connection.quote_string("foo")
  end

  def test_recovering_after_the_master_is_back_up
    User.create!
    $mysql_master.down!

    assert_raises(ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter::NoServerAvailableException) do
      User.create!
    end
    # bad state again.

    # now a dba or someone comes along and flips the read-only bit on the slave
    $mysql_slave.set_rw!
    User.create!
    UserSlave.first

    assert_equal $mysql_slave, master_connection
  ensure
    $mysql_master.up!
  end

  def test_losing_the_server_with_reconnect_on
    Reconnect.create!
    ReconnectSlave.first

    $mysql_master.down!

    assert Reconnect.first
    assert ReconnectSlave.first

    assert_raises(ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter::NoServerAvailableException) do
      Reconnect.create!
    end

    $mysql_slave.set_rw!
    Reconnect.create!
    ReconnectSlave.first
  ensure
    $mysql_master.up!
  end

  # test that when nothing else is available we can fall back to the master in a slave role
  def test_master_can_act_as_slave
    $mysql_slave.down!
    $mysql_slave_2.down!

    UserSlave.first
    assert_equal $mysql_master, slave_connection
  ensure
    $mysql_slave.up!
    $mysql_slave_2.up!
  end

  def test_connection_multiple_attempts
    # We're simulating connection timeout, so mocha's Expectation#times doesn't register the calls
    attempts = 0
    null_logger = Logger.new('/dev/null')
    config = { hosts: ['localhost'], connection_timeout: 0.01, connection_attempts: 5 }

    Mysql2::Client.stubs(:new).with do
      attempts += 1
      sleep 1
    end
    assert_raises(ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter::NoServerAvailableException) do
      ActiveRecord::ConnectionAdapters::MysqlFlexmasterAdapter.new(null_logger, config)
    end
    assert_equal 5, attempts
  end

  private

  def server_id(connection)
    connection.execute("SHOW GLOBAL VARIABLES LIKE 'server_id'").first.last.to_i
  end

  def server_id_for_class(klass)
    server_id(klass.connection)
  end

  def connection_for_class(klass)
    server_id = server_id_for_class(klass)
    [$mysql_master, $mysql_slave, $mysql_slave_2].find { |cx| cx.server_id == server_id }
  end

  def master_connection
    connection_for_class(User)
  end

  def slave_connection
    connection_for_class(UserSlave)
  end
end
