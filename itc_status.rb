# Invoke like this:
# ITC_ACCOUNTNAME='foo@bar.com' ITC_PASSWORD=password REDISTOGO_URL="redis://127.0.0.1:6379" bundle exec ruby itc_status.rb

module ItunesConnect

  class AppStatus
    require 'digest/md5'

    attr_accessor :date, :id, :name, :status, :user, :version

    def initialize(values = {})
      @date = values[:date]
      @id = values[:id]
      @name = values[:name]
      @status = values[:status]
      @user = values[:user]
      @version = values[:version]
    end

    def digest
      Digest::MD5.hexdigest "#{date}#{user}#{status}"
    end

    def summary
      "*#{name} #{version}* status is now *#{status}*."
    end

    def to_s
      "#{name}||#{version}||#{date}||#{user}||#{status}"
    end
  end

  class Scraper
    require 'capybara'
    require 'capybara/poltergeist'
    require 'faraday'
    require 'pry-byebug'
    require 'redis'

    APP_IDS = ["829841726", "940668352", "940668274", "719179248", "552197945"]
    ITC_SIGNIN_URL = "https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa"
    SLACK_WEBHOOK_ENDPOINT = "https://hooks.slack.com/services/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"
    STATUS_PAGE_URL = "https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa/wa/LCAppPage/viewStatusHistory?adamId=APPID&versionString=latest"
    VERSION_PAGE_URL = "https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa/wa/LCAppPage/viewStorePreview?adamId=APPID&versionString=latest"

    attr_reader :itc_accountname, :itc_password, :redistogo_url

    def initialize
      @itc_accountname = ENV['ITC_ACCOUNTNAME']
      @itc_password    = ENV['ITC_PASSWORD']
      @redistogo_url   = ENV['REDISTOGO_URL']

      Capybara.register_driver :poltergeist do |app|
        Capybara::Poltergeist::Driver.new(app, :phantomjs_options => ['--debug=no', '--load-images=no', '--ignore-ssl-errors=yes', '--ssl-protocol=TLSv1'], :debug => false, :js_errors => false)
      end
    end

    def scrape
      signin
      APP_IDS.each do |app_id|
        app_status = build_app_status app_id
        if update_redis app_status
          post_to_slack app_status
        end
      end
    end

    private

    def build_app_status(app_id)
      session.visit STATUS_PAGE_URL.gsub("APPID", app_id)
      date = session.first("#version-state-history-list table tr.even .versionStateHistory-col-0 p").text
      user = session.first("#version-state-history-list table tr.even .versionStateHistory-col-1 p").text
      status = session.first("#version-state-history-list table tr.even .versionStateHistory-col-2 p").text
      session.visit VERSION_PAGE_URL.gsub("APPID", app_id)
      name = session.find("label", text: "App Name").first(:xpath, ".//..").find("span").text
      version = session.find("label", text: "Version").first(:xpath, ".//..").find("span").text
      ItunesConnect::AppStatus.new(date: date, id: app_id, name: name, status: status, user: user, version: version)
    end

    def post_to_slack(app_status)
      Faraday.post(SLACK_WEBHOOK_ENDPOINT, payload: {text: app_status.summary}.to_json)
    end

    def redis
      return @redis if @redis
      uri = URI.parse(ENV["REDISTOGO_URL"])
      @redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
    end

    def session
      return @session if @session
      @session = Capybara::Session.new(:poltergeist)
      @session.driver.headers = { 'User-Agent' => "Mozilla/5.0 (Macintosh; Intel Mac OS X)" }
      @session
    end

    def signin
      session.visit ITC_SIGNIN_URL
      session.fill_in("theAccountName", with: itc_accountname)
      session.fill_in("theAccountPW", with: itc_password)
      session.find("body.signin a.btn-signin").click
    end

    def update_redis(app_status)
      previous_status_digest = redis.get "APP_ID_#{app_status.id}"
      new_status_digest = app_status.digest
      if previous_status_digest == new_status_digest
        puts "Status for APP_ID_#{app_status.id} unchanged: #{app_status}."
        false
      else
        puts "Writing new value for APP_ID_#{app_status.id}: #{app_status}."
        redis.set("APP_ID_#{app_status.id}", new_status_digest)
        true
      end
    end

  end
end

scraper = ItunesConnect::Scraper.new
scraper.scrape
