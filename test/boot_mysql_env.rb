#!/usr/bin/env ruby
# frozen_string_literal: true

require 'docker_server'

$mysql_master  = DockerServer::MySql.new(host: "dbs-1")
$mysql_slave   = DockerServer::MySql.new(host: "dbs-2")
$mysql_slave_2 = DockerServer::MySql.new(host: "dbs-3")

sleep(2) until $mysql_master.up? && $mysql_slave.up? && $mysql_slave_2.up?

$mysql_master.make_master
$mysql_slave.make_slave_of($mysql_master)
$mysql_slave_2.make_slave_of($mysql_slave)

$mysql_master.query("CREATE DATABASE flexmaster_test")
$mysql_master.query("CREATE TABLE flexmaster_test.users (" \
                      "id INT(10) NOT NULL AUTO_INCREMENT PRIMARY KEY, " \
                      "name VARCHAR(20)" \
                    ")")
$mysql_master.query("INSERT INTO flexmaster_test.users SET name='foo'")

$mysql_master.query("CREATE USER flex")
$mysql_master.query("GRANT ALL ON flexmaster_test.* TO flex")

sleep(0.5) until $mysql_slave.synced_with?($mysql_master) &&
                 $mysql_slave_2.synced_with?($mysql_slave)
