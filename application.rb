require 'rubygems'
require 'sinatra'
require 'rest_client'
require 'rack-flash'
require 'datamapper'
require 'crack'

use Rack::Flash

enable :sessions

DataMapper.setup(:default, ENV['DATABASE_URL'] || 'sqlite3://my.db')
DataObjects::Sqlite3.logger = DataObjects::Logger.new(STDOUT, 0)

class Post
  include DataMapper::Resource
  property :id, Serial
  property :title, String
  property :body, Text
  property :created_at, DateTime
end

class Feed
  include DataMapper::Resource
  property :id, Serial
  property :title, String
  property :url, String
  property :hub_url, String
  property :created_at, DateTime
  has n, :subscriptions

  def self.find_hub(url)
    feed_response = RestClient.get url
    hashed_feed = Crack::XML.parse(feed_response)
    hub = "n/a"
    if hashed_feed['rss']
      hub = hashed_feed['rss']['channel']['atom10:link']['href']
    elsif hashed_feed['feed']
      hub = hashed_feed['feed']['atom10:link']['href']
    end
  end
end

class Subscription
  include DataMapper::Resource
  property :id, Serial
  property :active, Boolean
  property :token, String
  property :last_response_code, String
  property :verified, String
  property :created_at, DateTime
  belongs_to :feed

  def subscribe
    response_code = RestClient.post(self.feed.hub_url, 'hub.mode' => 'subscribe', 'hub.callback' => 'http://eddorre.com/test', 'hub.topic' => 'http://feeds.feedburner.com/planetargon', 'hub.verify' => 'async', :content_type => 'application/x-www-form-urlencoded').code
    self.last_response_code = response_code
  end

  def unsubscribe

  end
end

def SimpleTokenGenerator
  def self.generate(token_size)

  end
end

DataMapper.auto_migrate!

get '/feed' do
  @feeds = Feed.all
  erb "/feeds/index".to_sym
end

get '/feed/new' do
  erb "/feeds/new".to_sym
end

post '/feed' do
  @feed = Feed.new(params[:feed])
  @feed.hub_url = Feed.find_hub(params[:feed][:url])
  @feed.save
  @feeds = Feed.all
  erb "/feeds/index".to_sym
end

post '/subscribe' do
  feed = Feed.get(params[:feed][:id])
  subscription = Subscription.new({ :feed_id => feed })
  subscription.subscribe
  erb :subscribe
end