require 'sinatra'
require 'json/ext' # for .to_json
require 'haml'
require 'uri'
require 'mongo'
require 'bcrypt'
require './helpers'
require 'prometheus/client'


configure do
    db = Mongo::Client.new([ ENV['DATABASE_URL'] || '127.0.0.1:27017' ],
        user: ENV['DATABASE_USER'] || '',
        password: ENV['DATABASE_PASS'] || '',
        database: ENV['DATABASE_NAME'] || 'user_posts',
        heartbeat_frequency: 2)
    set :mongo_db, db[:posts]
    set :comments_db, db[:comments]
    set :users_db, db[:users]
    set :bind, '0.0.0.0'
    enable :sessions
end

class Metrics
  def initialize(app)
    @app = app
    prometheus = Prometheus::Client.registry
    @request_count = Prometheus::Client::Counter.new(
      :ui_request_count,
      'App Request Count'
    )
    @request_response_time = Prometheus::Client::Histogram.new(
      :ui_request_response_time,
      'Request response time'
    )
    prometheus.register(@request_response_time)
    prometheus.register(@request_count)
  end

  def call(env)
    request_started_on = Time.now
    env['REQUEST_ID'] = SecureRandom.uuid # add unique ID to each request
    @status, @headers, @response = @app.call(env)
    request_ended_on = Time.now
    # prometheus metrics
    @request_response_time.observe({ path: env['REQUEST_PATH'] },
                             request_ended_on - request_started_on)
    @request_count.increment(method: env['REQUEST_METHOD'],
                             path: env['REQUEST_PATH'],
                             http_status: @status)
    [@status, @headers, @response]
  end
end

# Create and register metrics
prometheus = Prometheus::Client.registry
ui_health_gauge = Prometheus::Client::Gauge.new(
  :ui_health,
  'Health status of UI service'
)
prometheus.register(ui_health_gauge)

before do
  session[:flashes] = [] if session[:flashes].class != Array
end


get '/' do
  @title = 'All posts'
  begin
    @posts = JSON.parse(settings.mongo_db.find.sort(timestamp: -1).to_a.to_json)
  rescue
    session[:flashes] << { type: 'alert-danger', message: 'Can\'t show blog posts, some problems with database. <a href="." class="alert-link">Refresh?</a>' }
  end
  @flashes = session[:flashes]
  session[:flashes] = nil
  haml :index
end


get '/new' do
  @title = 'New post'
  @flashes = session[:flashes]
  session[:flashes] = nil
  haml :create
end

post '/new' do
  db = settings.mongo_db
  if params['link'] =~ URI::regexp
    begin
      result = db.insert_one title: params['title'], created_at: Time.now.to_i, link: params['link'], votes: 0
      db.find(_id: result.inserted_id).to_a.first.to_json
    rescue
      session[:flashes] << { type: 'alert-danger', message: 'Can\'t save your post, some problems with the post service' }
    else
      session[:flashes] << { type: 'alert-success', message: 'Post successuly published' }
    end
    redirect '/'
  else
    session[:flashes] << { type: 'alert-danger', message: 'Invalid URL' }
    redirect back
  end
end


get '/signup' do
  @title = 'Signup'
  @flashes = session[:flashes]
  session[:flashes] = nil
  haml :signup
end


get '/login' do
  @title = 'Login'
  @flashes = session[:flashes]
  session[:flashes] = nil
  haml :login
end


post '/signup' do
  db = settings.users_db
  password_salt = BCrypt::Engine.generate_salt
  password_hash = BCrypt::Engine.hash_secret(params[:password], password_salt)
  u = db.find(_id: params[:username]).to_a.first.to_json
  if u == "null"
    result = db.insert_one _id: params[:username], salt: password_salt, passwordhash: password_hash
    session[:username] = params[:username]
    session[:flashes] << { type: 'alert-success', message: 'User created' }
    redirect '/'
  else
    session[:flashes] << { type: 'alert-danger', message: 'User already exists' }
    redirect back
  end
end


post '/login' do
  db = settings.users_db
  u = db.find(_id: params[:username]).to_a.first.to_json
  if u != "null"
    user = JSON.parse(u)
    if user["passwordhash"] == BCrypt::Engine.hash_secret(params[:password], user["salt"])
      session[:username] = params[:username]
      redirect '/'
    else
      session[:flashes] << { type: 'alert-danger', message: 'Wrong username or password' }
      redirect back
    end
  else
    session[:flashes] << { type: 'alert-danger', message: 'Wrong username or password' }
    redirect back
  end
end


get '/logout' do
  session[:username] = nil
  redirect back
end


put '/post/:id/vote/:type' do
  if logged_in?
    id   = object_id(params[:id])
    post = JSON.parse(document_by_id(params[:id]))
    post['votes'] += params[:type].to_i

    settings.mongo_db.find(:_id => id).
      find_one_and_update('$set' => {:votes => post['votes']})
    document_by_id(id)
  else
    session[:flashes] << { type: 'alert-danger', message: 'You need to log in before you can vote' }
  end
  redirect back
end


get '/post/:id' do
  @title = 'Post'
  @post = JSON.parse(document_by_id(params[:id]))
  id   = object_id(params[:id])
  @comments = JSON.parse(settings.comments_db.find(post_id: "#{id}").to_a.to_json)
  @flashes = session[:flashes]
  session[:flashes] = nil
  haml :show
end


post '/post/:id/comment' do
  content_type :json
  db = settings.comments_db
  begin
    result = db.insert_one post_id: params[:id], name: session[:username], body: params['body'], created_at: Time.now.to_i
    db.find(_id: result.inserted_id).to_a.first.to_json
  rescue
    session[:flashes] << { type: 'alert-danger', message: 'Can\'t save your comment, some problems with the comment service' }
  else
    session[:flashes] << { type: 'alert-success', message: 'Comment successuly published' }
  end
    redirect back
end
