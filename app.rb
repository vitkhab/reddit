require 'sinatra'
require 'sinatra/reloader'
require 'json/ext' # for .to_json
require 'haml'
require 'uri'
require 'mongo'
require 'bcrypt'
require 'prometheus/client'
require 'rufus-scheduler'
require 'logger'
require 'faraday'
require 'zipkin-tracer'
require_relative 'helpers'

ZIPKIN_ENABLED ||= ENV['ZIPKIN_ENABLED'] || false

# Database connection info
DATABASE_URL  ||=  ENV['DATABASE_URL'] || 'mongodb://127.0.0.1:27017'
DATABASE_USER ||=  ENV['DATABASE_USER'] || ''
DATABASE_PASS ||=  ENV['DATABASE_PASS'] || ''
DATABASE_NAME ||= ENV['DATABASE_NAME'] || 'user_posts'

# App version and build info
#VERSION ||= File.read('VERSION').strip
#BUILD_INFO = File.readlines('build_info.txt')
@@host_info=ENV['HOSTNAME']
@@env_info=ENV['ENV']

# Zipkin opts
set :zipkin_enabled, ZIPKIN_ENABLED
zipkin_config = {
    service_name: 'ui_app',
    service_port: 9292,
    sample_rate: 1,
    sampled_as_boolean: false,
    log_tracing: true,
    json_api_host: 'http://zipkin:9411/api/v1/spans'
  }

if settings.zipkin_enabled?
  use ZipkinTracer::RackHandler, zipkin_config
end

configure do
  set :server, :puma
  set :logging, false
#  set :mylogger, Logger.new(STDOUT)
  set :mylogger, Logger.new('reddit.log')
  Mongo::Logger.logger = settings.mylogger
  
  db = Mongo::Client.new(DATABASE_URL,
  # user: DATABASE_USER,
  # password: DATABASE_PASS,
  # database: DATABASE_NAME,
  heartbeat_frequency: 2)
    # db = Mongo::Client.new(DATABASE_URL,
    #     user: DATABASE_USER,
    #     password: DATABASE_PASS,
    #     database: DATABASE_NAME,
    #     heartbeat_frequency: 2)
    set :mongo_db, db[:posts]
    set :comments_db, db[:comments]
    set :users_db, db[:users]
    set :bind, '0.0.0.0'
    enable :sessions
end


# Create and register metrics
prometheus = Prometheus::Client.registry
ui_health_gauge = Prometheus::Client::Gauge.new(
  :ui_health,
  'Health status of UI service'
)
prometheus.register(ui_health_gauge)
comment_health_gauge = Prometheus::Client::Gauge.new(
  :comment_health,
  'Health status of Comment service'
)
comment_health_db_gauge = Prometheus::Client::Gauge.new(
  :comment_health_mongo_availability,
  'Check if MongoDB is available to Comment'
)
comment_count = Prometheus::Client::Counter.new(
  :comment_count,
  'A counter of new comments'
)
prometheus.register(comment_health_gauge)
prometheus.register(comment_health_db_gauge)
prometheus.register(comment_count)

# Schedule health check function
scheduler = Rufus::Scheduler.new
scheduler.every '5s' do
  #check = JSON.parse(http_healthcheck_handler(POST_URL, COMMENT_URL, VERSION))
  check = JSON.parse(healthcheck_handler(DATABASE_URL))
  set_health_gauge(comment_health_gauge, check['status'])
  set_health_gauge(comment_health_db_gauge, check['dependent_services']['commentdb'])
  set_health_gauge(ui_health_gauge, check['status'])
end

# before each request
before do
  session[:flashes] = [] if session[:flashes].class != Array
  env['rack.logger'] = settings.mylogger # set custom logger
end

# after each request
after do
  request_id = env['REQUEST_ID'] || 'null'
  logger.info("service=ui | event=request | path=#{env['REQUEST_PATH']} | " \
              "request_id=#{request_id} | " \
              "remote_addr=#{env['REMOTE_ADDR']} | " \
              "method= #{env['REQUEST_METHOD']} | " \
              "response_status=#{response.status}")
end

get '/' do
  @title = 'All posts'
  begin
    @posts = JSON.parse(settings.mongo_db.find.sort(timestamp: -1).to_a.to_json)
  rescue StandardError => e
    flash_danger('Can\'t show blog posts, some problems with the post ' \
                 'service. <a href="." class="alert-link">Refresh?</a>')
    log_event('error', 'show_all_posts',
              "Failed to read from Post service. Reason: #{e.message}")
  else
    log_event('info', 'show_all_posts',
              'Successfully showed the home page with posts')
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
    rescue StandardError => e
      flash_danger("Can't save your post, some problems with the post service")
      log_event('error', 'post_create',
                "Failed to create a post. Reason: #{e.message}", params)
    else
      flash_success('Post successuly published')
      log_event('info', 'post_create', 'Successfully created a post', params)
    end
    redirect '/'
  else
    flash_danger('Invalid URL')
    log_event('warning', 'post_create', 'Invalid URL', params)
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
  begin
    id   = object_id(params[:id])
    post = JSON.parse(document_by_id(params[:id]))
    post['votes'] += params[:type].to_i

    settings.mongo_db.find(:_id => id).
      find_one_and_update('$set' => {:votes => post['votes']})
    document_by_id(id)
  rescue StandardError => e
    flash_danger('Can\'t vote, some problems with the post service')
    log_event('error', 'vote',
              "Failed to vote. Reason: #{e.message}", params)
  else
    log_event('info', 'vote', 'Successful vote', params)
  end
  redirect back
end


get '/post/:id' do
  @title = 'Post'

  begin
    @post = JSON.parse(document_by_id(params[:id]))
  rescue StandardError => e
    log_event('error', 'show_post',
              "Counldn't show the post. Reason: #{e.message}", params)
    halt 404, 'Not found'
  end

  id   = object_id(params[:id])
  begin
    @comments = JSON.parse(settings.comments_db.find(post_id: "#{id}").to_a.to_json)
  rescue StandardError => e
    log_event('error', 'show_post',
              "Counldn't show the comments. Reason: #{e.message}", params)
    flash_danger("Can't show comments, some problems with the comment service")
  else
    log_event('info', 'show_post',
              'Successfully showed the post', params)
  end

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
  rescue StandardError => e
    log_event('error', 'create_comment',
              "Counldn't create a comment. Reason: #{e.message}", params)
    flash_danger("Can\'t save the comment,
                 some problems with the comment service")
  else
    log_event('info', 'create_comment',
              'Successfully created a new post', params)
    comment_count.increment

    flash_success('Comment successuly published')
  end
    redirect back
end

# health check endpoint
get '/healthcheck' do
  http_healthcheck_handler()
end

get '/*' do
  halt 404, 'Page not found'
end
