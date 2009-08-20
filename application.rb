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
  property :feed_url, String
  property :active, Boolean
  property :token, String
  property :last_response_code, String
  property :verified, String
  property :created_at, DateTime
  belongs_to :feed

  def subscribe
    self.token = SimpleTokenGenerator.generate(7)
    self.last_response_code = response_code = self.call_hub('subscribe', 'http://eddorre.com/test', 'async' )
    
    if response_code == 202
      self.active = true
    end
    
    self.save
  end

  def unsubscribe
    self.last_response_code = response_code = self.call_hub('unsubscribe', 'http://eddorre.com/test', 'async' )
    
    if response_code == 202
      self.active = false
    end
    
    self.save
  end
  
  def call_hub(hub_mode, endpoint, verify_mode)
    RestClient.post(self.feed.hub_url, 'hub.mode' => hub_mode, 
    'hub.callback' => endpoint, 'hub.topic' => self.feed.url, 
    'hub.verify' => verify_mode, 'hub.verify_token' => self.token, :content_type => 'application/x-www-form-urlencoded').code
  end
  
  def verify
    self.verified = true
    self.save
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

post '/subscription' do
  feed = Feed.get(params[:feed][:id])
  subscription = Subscription.new({ :feed_id => feed.id, :feed_url => feed.url })
  subscription.subscribe
  @subscriptions = Subscription.all
  erb "subscriptions/index".to_sym
end

get '/verify' do
  verify_token = params['hub.verify_token']
  feed_url = params['hub.topic']
  hub_challenge = params['hub.challenge']
  
  if subscription = Subscription.first(:token => verify_token, :feed_url => feed_url)
    subscription.verify
    status 200
    hub_challenge
  else
    status 404
    "Not found"
  end
end

post '/endpoint' do
  content = params
end

get '/post' do
  @posts = Post.all
  erb "/posts/index".to_sym
end

get '/post/:post_id' do
  @post = Post.get(params[:post_id])
  erb "/posts/show".to_sym
end


get '/post/feed' do
  @posts = Post.all
  builder do |xml|
    xml.instruct! :xml, :version => '1.0'
    xml.rss :version => "2.0" do
      xml.channel do
        xml.title "pshb"
        xml.description "Pubsubhubbub Test"
        xml.link "http://linkhere.com"
        
        @posts.each do |post|
          xml.item do
            xml.title post.title
            xml.link "http://linkhere.com/post/#{post.id}"
            xml.description post.body
            xml.pubDate Time.parse(post.created_at.to_s).rfc822()
            xml.guid "http://linkhere.com/post/#{post.id}"
          end
        end
      end
    end
  end
end

get '/post/new' do
  erb "/posts/new".to_sym
end

post '/post' do
  @post = Post.new(params[:post])
  @post.save
  
  @posts = Post.all
  erb "/posts/index".to_sym
end
