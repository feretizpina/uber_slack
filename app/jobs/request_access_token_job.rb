class RequestAccessTokenJob < ActiveJob::Base
  queue_as :auth
  sidekiq_options retry: false

  BASE_PARAMS = {
    'client_secret' => ENV['uber_client_secret'],
    'client_id'     => ENV['uber_client_id'],
    'grant_type'    => 'authorization_code',
    'redirect_uri'  => ENV['uber_callback_url']
  }.freeze



  # Exchange temporary auth code from Uber for a semipermanent auth token
  def perform(auth_code)
    post_params = BASE_PARAMS.merge("code" => auth_code)
    resp = RestClient.post(ENV['uber_oauth_url'], post_params)
    update_authorization(JSON.parse(resp.body))
  end

  private

  def update_authorization(response)
    access_token = response['access_token']
    refresh_token = response['refresh_token']
    expires_in = response['expires_in']

    Authorization.find_by(session_token: session[:session_token]).tap do |auth|
      auth.update!(
        uber_auth_token: access_token,
        uber_refresh_token: refresh_token,
        uber_access_token_expiration_time: Time.now + expires_in
      )
    end
  end
end
