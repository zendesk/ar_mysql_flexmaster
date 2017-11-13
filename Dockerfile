FROM ruby:2.4.2

RUN apt-get update -qq && \
    apt-get install -y mysql-client

RUN mkdir /flexmaster
WORKDIR /flexmaster

ADD bin /flexmaster/bin
ADD ar_mysql_flexmaster.gemspec /flexmaster/ar_mysql_flexmaster.gemspec

RUN md5sum ar_mysql_flexmaster.gemspec

ADD Gemfile /flexmaster/Gemfile
ADD Gemfile.lock /flexmaster/Gemfile.lock

RUN bundle install

ADD . /flexmaster
