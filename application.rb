require 'rubygems'
require 'sinatra'
require 'rest_client'
require 'rack-flash'
require 'datamapper'
require 'crack'
require 'logger'

use Rack::Flash

enable :sessions, :logging

DataMapper.setup(:default, ENV['DATABASE_URL'] || 'sqlite3://my.db')
# DataObjects::Sqlite3.logger = DataObjects::Logger.new(STDOUT, 0)

helpers do
  def protected!
    response['WWW-Authenticate'] = %(Basic realm="Testing HTTP Auth") and \
    throw(:halt, [401, "Not authorized\n"]) and \
    return unless authorized?
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == ['carlos', 'meep']
  end
end

configure do
  Log = Logger.new(STDOUT)
  Log.level = Logger::INFO
end

class Post
  include DataMapper::Resource
  property :id, Serial
  property :title, String
  property :body, Text
  property :created_at, DateTime
end

class FeedEntry
  include DataMapper::Resource
  property :id, Serial
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
    debug = hashed_feed
    if hashed_feed['rss']
      if hashed_feed['rss']['channel']['atom10:link'].is_a?(Array)
        hashed_feed['rss']['channel']['atom10:link'].each do |array|
          if array['rel']['hub']
            hub = array['href']
          end
        end
      end
    elsif hashed_feed['feed']
      hub = hashed_feed['feed']['atom10:link']['href']
    end
    
    return [debug, hub]
  end
end

class Subscription
  include DataMapper::Resource
  property :id, Serial
  property :feed_url, String
  property :active, Boolean
  property :token, String
  property :last_response_code, String
  property :verified, String
  property :created_at, DateTime
  belongs_to :feed

  def subscribe
    self.token = SimpleTokenGenerator.generate(7)
    self.last_response_code = response_code = self.call_hub('subscribe', 'http://pshb.heroku.com/endpoint', 'async' )
    
    if response_code == 202
      self.update_attributes(:active => true)
    end
  end

  def unsubscribe
    self.last_response_code = response_code = self.call_hub('unsubscribe', 'http://pshb.heroku.com/endpoint', 'async' )
    
    if response_code == 202
      self.update_attributes(:active => false)
    end
  end
  
  def call_hub(hub_mode, endpoint, verify_mode)
    RestClient.post(self.feed.hub_url, 'hub.mode' => hub_mode, 
    'hub.callback' => endpoint, 'hub.topic' => self.feed.url, 
    'hub.verify' => verify_mode, 'hub.verify_token' => self.token, :content_type => 'application/x-www-form-urlencoded').code
  end
  
  def verify
    self.update_attributes(:verified => true)
  end
end

class SimpleTokenGenerator
  def self.generate(token_size)
     characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890'
     temp_token = ''
     srand
     token_size.times do
       pos = rand(characters.length)
       temp_token += characters[pos..pos]
     end
     temp_token
  end
end

DataMapper.auto_upgrade!

get '/feed' do
  protected!
  @feeds = Feed.all
  erb "/feeds/index".to_sym
end

get '/feed/new' do
  protected!
  erb "/feeds/new".to_sym
end

post '/feed' do
  protected!
  @feed = Feed.new(params[:feed])
  response = Feed.find_hub(params[:feed][:url])
  @feed.hub_url = response.last
  @debug = response.first
  @feed.save
  @feeds = Feed.all
  erb "/feeds/index".to_sym
end

delete '/feed' do
  protected!
  feed = Feed.get(params[:feed][:id])
  if feed.subscriptions.size > 0
    feed.subscriptions.each do |subscription|
      if subscription.active
        subscription.unsubscribe
        if subscription.last_response_code == 202
          subscription.destroy
        else
          return false
        end
      end
    end
  end
  feed.destroy
  @feeds = Feed.all
  erb "/feeds/index".to_sym
end

get '/subscription' do
  @subscriptions = Subscription.all
  erb "subscriptions/index".to_sym
end

post '/subscription' do
  protected!
  feed = Feed.get(params[:feed][:id])
  subscription = Subscription.new({ :feed_id => feed.id, :feed_url => feed.url })
  subscription.subscribe
  @subscriptions = Subscription.all
  erb "subscriptions/index".to_sym
end

delete '/subscription' do
  protected!
  subscription = Subscription.get(params[:subscription][:id])
  subscription.unsubscribe
  @subscriptions = Subscription.all
  erb "subscriptions/index".to_sym
end

get '/endpoint' do
  verify_token = params['hub.verify_token']
  feed_url = params['hub.topic']
  hub_challenge = params['hub.challenge']
  subscription = Subscription.first(:token => verify_token, :feed_url => feed_url)
  if not subscription.nil?
    subscription.verify
    throw :halt, [ 200, hub_challenge ]
  else
    throw :halt, [ 404, "Not found" ]  
  end
end

post '/endpoint' do
  Log.info("POST Endpoint Content Type #{request.content_type}")
  if request.content_type == 'application/atom+xml' || request.content_type == 'application/rss+xml'
    content = request.body.string
    feed_entry = FeedEntry.new({ :body => content })
    if feed_entry.save
      status 200
    else
      throw :halt,  [ 404, "Not found"]
      "Not found"
    end
  else
    throw :halt,  [ 500, "Invalid content type"]
  end
end

get '/post' do
  protected!
  @posts = Post.all
  erb "/posts/index".to_sym
end

get '/post/feed' do
  @posts = Post.all
  builder do |xml|
    xml.instruct! :xml, :version => '1.0'
    xml.rss :version => "2.0" do
      xml.channel do
        xml.title "pshb"
        xml.description "Pubsubhubbub Test"
        xml.link "http://pshb.heroku.com"
        
        @posts.each do |post|
          xml.item do
            xml.title post.title
            xml.link "http://pshb.heroku.com/post/#{post.id}"
            xml.description post.body
            xml.pubDate Time.parse(post.created_at.to_s).rfc822()
            xml.guid "http://pshb.heroku.com/post/#{post.id}"
          end
        end
      end
    end
  end
end

get '/post/new' do
  protected!
  erb "/posts/new".to_sym
end

post '/post' do
  protected!
  @post = Post.new(params[:post])
  @post.save
  
  @posts = Post.all
  erb "/posts/index".to_sym
end

get '/feed_entries' do
  protected!
  @feed_entries = FeedEntry.all
  erb "/feed_entries/index".to_sym
end
