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

def authorize
  client_id = Google::Auth::ClientId.from_file(CREDENTIALS_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: TOKEN_PATH)
  authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
  begin
    credentials = authorizer.get_credentials(USER_ID)
  rescue RuntimeError
    authorizer, credentials = handle_token_error(client_id)
  end
  credentials = authorize_with_code(authorizer) if credentials.nil?
  credentials
end

def handle_token_error(client_id)
  puts '|-----------------------------------------------------------------------------------------|'
  puts '| Sorry file token.yaml has invalid code, you will be prompted to authorize               |'
  puts '| Извините файл token.yaml содержит не правильный код, пройдите авторизацию ещё раз       |'
  puts '|-----------------------------------------------------------------------------------------|'
  File.delete(TOKEN_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: TOKEN_PATH)
  authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
  [authorizer, nil]
end

def authorize_with_code(authorizer)
  url = authorizer.get_authorization_url base_url: OOB_URI
  authorize_with_code_message(url)
  begin
    code = gets.chomp
    credentials = authorizer.get_and_store_credentials_from_code(user_id: USER_ID, code: code, base_url: OOB_URI)
  rescue Signet::AuthorizationError => e
    puts e.message, 'Try one more time (Попробуйте ещё раз):'
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

def initialize_api
  service = Google::Apis::GmailV1::GmailService.new
  service.client_options.application_name = APPLICATION_NAME
  service.authorization = authorize
  service
end

def create_email(subject, path, body)
  message = Mail.new
  message.header['To'] = RECPIENT
  message.header['Subject'] = subject
  message.body = body + BODY
  message.charset = 'UTF-8'
  message.add_file(path)
  Google::Apis::GmailV1::Message.new(raw: message.to_s)
end

def send_mail(subject, path, body)
  user_id = 'me'
  message = create_email(subject, path, body)
  service = initialize_api
  begin
    service.send_user_message(user_id, message)
  rescue Google::Apis::AuthorizationError
    puts 'Authorization error, please try again'
  end
end

def set_initial_data
  if File.file?('db.json')
    return data = {} if File.zero?('db.json')

    file = File.read('db.json')
    data = JSON.parse(file)
  else
    FileUtils.touch('db.json')
    data = {}
  end
  data
end

def pdf_body(filepath)
  reader = PDF::Reader.new(filepath)
  str = reader.pages.first.text[0...26].gsub("\n", ' ').squeeze(' ')
  str.include?('Faktura') ? "#{str}\n" : ''
end

def filenames_array
  FileUtils.cd(DOCUMENTS_PATH) do
    return Dir.entries('.').select { |f| f.include?('.pdf') }
  end
end

def file_sent?(data, filename)
  data[DOCUMENTS_PATH][filename] = {} if data[DOCUMENTS_PATH][filename].nil?
  data[DOCUMENTS_PATH][filename]['sent'] = 'false' if data[DOCUMENTS_PATH][filename]['sent'].nil?
  data[DOCUMENTS_PATH][filename]['sent']
end

def create_emails_array(data)
  filenames_array.map do |filename|
    next if file_sent?(data, filename) == 'true'

    {
      subject: File.basename(filename, '.pdf'),
      filepath: File.join(DOCUMENTS_PATH, filename),
      filename: filename,
      body: pdf_body(File.join(DOCUMENTS_PATH, filename))
    }
  end
end

data = set_initial_data
data[DOCUMENTS_PATH] = {} if data[DOCUMENTS_PATH].nil?

emails = create_emails_array(data)
emails.compact.each do |email|
  send_mail(email[:subject], email[:filepath], email[:body])
  puts "#{email[:body]}Email #{email[:filename]} successfuly send"
  data[DOCUMENTS_PATH][email[:filename]]['faktura'] = email[:body].gsub("\n", '')
  data[DOCUMENTS_PATH][email[:filename]]['sent'] = 'true'
end

puts JSON.pretty_generate(data)
File.write('db.json', JSON.dump(data))
