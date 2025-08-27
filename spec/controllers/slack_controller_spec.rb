# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SlackController, type: :controller do
  let(:valid_signature) { 'v0=test_signature' }
  let(:timestamp) { Time.current.to_i.to_s }
  let(:signing_secret) { 'test_signing_secret' }
  
  before do
    stub_const('ENV', ENV.to_hash.merge({
      'SLACK_SIGNING_SECRET' => signing_secret,
      'SLACK_BOT_TOKEN' => 'xoxb-test-token',
      'SLACK_ENABLED' => 'true'
    }))
    
    allow(controller).to receive(:verify_slack_request).and_return(true)
  end

  describe 'POST #commands' do
    let(:command_params) do
      {
        token: 'test-token',
        team_id: 'T1234567890',
        team_domain: 'test-team',
        channel_id: 'C1234567890',
        channel_name: 'general',
        user_id: 'U1234567890',
        user_name: 'testuser',
        command: '/bot-status',
        text: '',
        response_url: 'https://hooks.slack.com/commands/1234/5678',
        trigger_id: '12345.67890.abcdef'
      }
    end

    context 'with valid request' do
      before do
        allow(SlackCommandHandler).to receive(:handle_command).and_return({
          text: 'Bot status response',
          response_type: 'in_channel'
        })
      end

      it 'processes command successfully' do
        post :commands, params: command_params
        
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['text']).to eq('Bot status response')
      end

      it 'passes correct parameters to handler' do
        expect(SlackCommandHandler).to receive(:handle_command) do |params|
          expect(params[:command]).to eq('/bot-status')
          expect(params[:user_id]).to eq('U1234567890')
          expect(params[:text]).to eq('')
        end
        
        post :commands, params: command_params
      end
    end

    context 'with URL verification challenge' do
      let(:challenge_params) do
        {
          type: 'url_verification',
          challenge: 'test_challenge_string',
          token: 'test-token'
        }
      end

      it 'responds to URL verification challenge' do
        post :commands, params: challenge_params
        
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['challenge']).to eq('test_challenge_string')
      end
    end

    context 'with invalid signature' do
      before do
        allow(controller).to receive(:verify_slack_request).and_return(false)
      end

      it 'returns unauthorized status' do
        post :commands, params: command_params
        
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when command handler raises error' do
      before do
        allow(SlackCommandHandler).to receive(:handle_command).and_raise(StandardError.new('Test error'))
      end

      it 'returns error response' do
        post :commands, params: command_params
        
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['text']).to include('Error processing command')
      end
    end
  end

  describe 'POST #events' do
    let(:event_params) do
      {
        type: 'event_callback',
        event: {
          type: 'message',
          channel: 'D1234567890',
          channel_type: 'im',
          user: 'U1234567890',
          text: 'Hello bot',
          ts: '1234567890.123456'
        }
      }
    end

    context 'with valid request' do
      it 'processes event successfully' do
        post :events, params: event_params
        
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['ok']).to be true
      end
    end

    context 'with URL verification challenge' do
      let(:challenge_params) do
        {
          type: 'url_verification',
          challenge: 'event_challenge_string'
        }
      end

      it 'responds to URL verification challenge' do
        post :events, params: challenge_params
        
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['challenge']).to eq('event_challenge_string')
      end
    end

    context 'with direct message event' do
      let(:mock_client) { instance_double(Slack::Web::Client) }
      
      before do
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage)
      end

      it 'responds to direct messages' do
        expect(mock_client).to receive(:chat_postMessage) do |args|
          expect(args[:channel]).to eq('D1234567890')
          expect(args[:text]).to include('Coinbase Futures Trading Bot')
        end
        
        post :events, params: event_params
      end
    end

    context 'with app mention event' do
      let(:mention_params) do
        {
          type: 'event_callback',
          event: {
            type: 'app_mention',
            channel: 'C1234567890',
            user: 'U1234567890',
            text: '<@U0BOTUSER> help',
            ts: '1234567890.123456'
          }
        }
      end
      
      let(:mock_client) { instance_double(Slack::Web::Client) }
      
      before do
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage)
      end

      it 'responds to app mentions' do
        expect(mock_client).to receive(:chat_postMessage) do |args|
          expect(args[:channel]).to eq('C1234567890')
          expect(args[:thread_ts]).to eq('1234567890.123456')
          expect(args[:text]).to include('slash commands')
        end
        
        post :events, params: mention_params
      end
    end

    context 'when event processing raises error' do
      before do
        allow(controller).to receive(:handle_event_callback).and_raise(StandardError.new('Event error'))
      end

      it 'returns ok false' do
        post :events, params: event_params
        
        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['ok']).to be false
      end
    end
  end

  describe 'GET #health' do
    let(:mock_client) { instance_double(Slack::Web::Client) }
    
    before do
      allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
    end

    context 'when Slack is properly configured and connected' do
      before do
        allow(mock_client).to receive(:auth_test).and_return({
          'ok' => true,
          'user_id' => 'U0BOTUSER',
          'team' => 'Test Team'
        })
      end

      it 'returns healthy status' do
        get :health
        
        expect(response).to have_http_status(:success)
        
        body = JSON.parse(response.body)
        expect(body['slack_enabled']).to be true
        expect(body['bot_token_configured']).to be true
        expect(body['api_connection']).to be true
        expect(body['bot_user_id']).to eq('U0BOTUSER')
        expect(body['team_name']).to eq('Test Team')
      end
    end

    context 'when Slack API connection fails' do
      before do
        allow(mock_client).to receive(:auth_test).and_raise(Slack::Web::Api::Errors::SlackError.new('invalid_auth'))
      end

      it 'returns unhealthy status' do
        get :health
        
        expect(response).to have_http_status(:service_unavailable)
        
        body = JSON.parse(response.body)
        expect(body['api_connection']).to be false
        expect(body['api_error']).to include('invalid_auth')
      end
    end

    context 'when Slack is disabled' do
      before do
        stub_const('ENV', ENV.to_hash.merge('SLACK_ENABLED' => 'false'))
      end

      it 'returns disabled status' do
        get :health
        
        expect(response).to have_http_status(:service_unavailable)
        
        body = JSON.parse(response.body)
        expect(body['slack_enabled']).to be false
        expect(body['api_connection']).to be false
      end
    end
  end

  describe '#verify_slack_request' do
    let(:request_body) { 'test=body&data=here' }
    let(:correct_signature) do
      sig_basestring = "v0:#{timestamp}:#{request_body}"
      'v0=' + OpenSSL::HMAC.hexdigest('SHA256', signing_secret, sig_basestring)
    end

    before do
      allow(controller).to receive(:verify_slack_request).and_call_original
      request.headers['X-Slack-Request-Timestamp'] = timestamp
      request.headers['X-Slack-Signature'] = correct_signature
      allow(request).to receive(:raw_post).and_return(request_body)
    end

    context 'with valid signature' do
      it 'returns true' do
        result = controller.send(:verify_slack_request, request)
        expect(result).to be true
      end
    end

    context 'with invalid signature' do
      before do
        request.headers['X-Slack-Signature'] = 'v0=invalid_signature'
      end

      it 'returns false' do
        result = controller.send(:verify_slack_request, request)
        expect(result).to be false
      end
    end

    context 'with old timestamp' do
      before do
        old_timestamp = (Time.current - 10.minutes).to_i.to_s
        request.headers['X-Slack-Request-Timestamp'] = old_timestamp
      end

      it 'returns false' do
        result = controller.send(:verify_slack_request, request)
        expect(result).to be false
      end
    end

    context 'without signing secret configured' do
      before do
        stub_const('ENV', ENV.to_hash.merge('SLACK_SIGNING_SECRET' => nil))
      end

      it 'returns true (skips verification)' do
        result = controller.send(:verify_slack_request, request)
        expect(result).to be true
      end
    end
  end
end