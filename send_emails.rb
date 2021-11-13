# frozen_string_literal: true

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  ruby '>= 2.7.0'
  gem 'google-api-client'
  gem 'mail'
  gem 'json'
  gem 'pdf-reader'
end

require 'google/apis/gmail_v1'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'mail'
require 'json'
require 'pdf-reader'

config_file = File.read('config.json')
config = JSON.parse(config_file)
DOCUMENTS_PATH = config['documents_path']
RECPIENT = config['recipient']
BODY = config['body']

puts '|-----------------------------------------------------------------------------------------|'
puts '| Please check if configs correct, if configs correct press Enter, else stop sript        |'
puts '| Пожалуйста проверьте настройки и нажмите Enter, если обнаружили ошибку остановите скрипт|'
puts '|-----------------------------------------------------------------------------------------|'
puts "body: #{BODY}"
puts "recipient: #{RECPIENT}"
puts "path to documents: #{DOCUMENTS_PATH}"
gets

OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'
APPLICATION_NAME = 'Send emails with attachment'
CREDENTIALS_PATH = 'credentials.json'
TOKEN_PATH = 'token.yaml'
USER_ID = 'default'
SCOPE = Google::Apis::GmailV1::AUTH_GMAIL_COMPOSE

class Authorizer
  attr_reader :service

  def initialize
    @service = Google::Apis::GmailV1::GmailService.new
    @client_id = Google::Auth::ClientId.from_file(CREDENTIALS_PATH)
  end

  def initialize_api
    @service.client_options.application_name = APPLICATION_NAME
    @service.authorization = authorize
  end

  private

  def authorize
    begin
      retries ||= 0
      token_store = Google::Auth::Stores::FileTokenStore.new(file: TOKEN_PATH)
      authorizer = Google::Auth::UserAuthorizer.new(@client_id, SCOPE, token_store)
      credentials = authorizer.get_credentials(USER_ID)
    rescue RuntimeError
      File.delete(TOKEN_PATH)
      retry if (retries += 1) < 2
    end
    credentials.nil? ? authorize_with_code(authorizer) : credentials
  end

  def authorize_with_code(authorizer)
    url = authorizer.get_authorization_url base_url: OOB_URI
    authorize_with_code_message(url)
    begin
      code = gets.chomp
      credentials = authorizer.get_and_store_credentials_from_code(user_id: USER_ID, code: code, base_url: OOB_URI)
    rescue Signet::AuthorizationError
      puts 'Try one more time, code incorrect (Попробуйте ещё раз, код не правильный):'
      retry
    end
    credentials
  end

  def authorize_with_code_message(url)
    puts '|-----------------------------------------------------------------------------------------|'
    puts '| Open the following URL in the browser and enter the resulting code after authorization: |'
    puts '| Откройте ссылку в браузере и введите код который получите после авторизации:            |'
    puts '|-----------------------------------------------------------------------------------------|'
    puts ''
    puts url
    puts ''
    puts 'Enter code (Введите код):'
  end
end

class Email
  attr_reader :filename, :body

  def initialize(filename)
    @filename = filename
    @filepath = File.join(DOCUMENTS_PATH, filename)
    @body = create_body
  end

  def send_mail(authorizer)
    retries ||= 0
    service = authorizer.service
    service.send_user_message('me', create_message)
  rescue Google::Apis::AuthorizationError
    File.delete(TOKEN_PATH)
    authorizer.initialize_api
    retry if (retries += 1) < 2
  end

  private

  def create_message
    message = Mail.new
    message.header['To'] = RECPIENT
    message.header['Subject'] = File.basename(filename, '.pdf')
    message.body = @body + BODY
    message.charset = 'UTF-8'
    message.add_file(@filepath)
    Google::Apis::GmailV1::Message.new(raw: message.to_s)
  end

  def create_body
    reader = PDF::Reader.new(@filepath)
    str = reader.pages.first.text[0...26].gsub("\n", ' ').squeeze(' ')
    str.include?('Faktura') ? "#{str}\n" : ''
  end
end

class MyData
  attr_accessor :data, :data_path
  attr_reader :emails

  def initialize
    @data = initial_data
    @data[DOCUMENTS_PATH] = @data[DOCUMENTS_PATH].nil? ? {} : @data[DOCUMENTS_PATH]
    @data_path = @data[DOCUMENTS_PATH]
    @emails = create_emails_array.compact
  end

  def show_data
    puts JSON.pretty_generate(@data)
  end

  def save_data
    File.write('db.json', JSON.dump(@data))
  end

  private

  def create_emails_array
    filenames = Dir.entries(DOCUMENTS_PATH).select { |f| f.include?('.pdf') }
    filenames.map do |filename|
      file_sent(filename)
      next if @data_path[filename]['sent'] == 'true'

      Email.new(filename)
    end
  end

  def file_sent(filename)
    @data_path[filename] = {} if @data_path[filename].nil?
    @data_path[filename]['sent'] = 'false' if @data_path[filename]['sent'].nil?
  end

  def initial_data
    if File.file?('db.json')
      return @data = {} if File.zero?('db.json')

      file = File.read('db.json')
      @data = JSON.parse(file)
    else
      FileUtils.touch('db.json')
      @data = {}
    end
  end
end

data_obj = MyData.new
emails = data_obj.emails
if !emails.empty?
  service = Authorizer.new
  service.initialize_api
  emails.each do |email|
    email.send_mail(service)
    puts "#{email.body}Email #{email.filename} successfuly send"
    data_obj.data_path[email.filename]['faktura'] = email.body.gsub("\n", '')
    data_obj.data_path[email.filename]['sent'] = 'true'
  end
end

puts 'State of db:'
data_obj.show_data
data_obj.save_data
