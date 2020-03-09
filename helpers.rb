def flash_danger(message)
  session[:flashes] << { type: 'alert-danger', message: message }
end

def flash_success(message)
  session[:flashes] << { type: 'alert-success', message: message }
end

def log_event(type, name, message, params = '{}')
  case type
  when 'error'
    logger.error('service=ui | ' \
                 "event=#{name} | " \
                 "request_id=#{request.env['REQUEST_ID']} | " \
                 "message=\'#{message}\' | " \
                 "params: #{params.to_json}")
  when 'info'
    logger.info('service=ui | ' \
                "event=#{name} | " \
                "request_id=#{request.env['REQUEST_ID']} | " \
                "message=\'#{message}\' | " \
                "params: #{params.to_json}")
  when 'warning'
    logger.warn('service=ui | ' \
                "event=#{name} | " \
                "request_id=#{request.env['REQUEST_ID']} | " \
                "message=\'#{message}\' |  " \
                "params: #{params.to_json}")
  end
end

def http_healthcheck_handler()
  status = 1

  healthcheck = { status: status}
  healthcheck.to_json
end

def healthcheck_handler(db_url)
  begin
    commentdb_test = Mongo::Client.new(db_url,
                                       server_selection_timeout: 2)
    commentdb_test.database_names
    commentdb_test.close
  rescue StandardError
    commentdb_status = 0
  else
    commentdb_status = 1
  end

  status = commentdb_status
  healthcheck = {
    status: status,
    dependent_services: {
      commentdb: commentdb_status
    }
  }

  healthcheck.to_json
end

def set_health_gauge(metric, value)
  metric.set(
    {
      version: 1.0
    },
    value
  )
end

helpers do
  # a helper method to turn a string ID
  # representation into a BSON::ObjectId
  def object_id val
    begin
      BSON::ObjectId.from_string(val)
    rescue BSON::ObjectId::Invalid
      nil
    end
  end

  def document_by_id id
    id = object_id(id) if String === id
    if id.nil?
      {}.to_json
    else
      document = settings.mongo_db.find(:_id => id).to_a.first
      (document || {}).to_json
    end
  end

  def logged_in?
      if session[:username].nil?
          return false
      else
          return true
      end
  end
end
