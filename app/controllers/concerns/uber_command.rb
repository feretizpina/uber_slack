require 'addressable/uri'

BASE_URL = ENV["uber_base_url"]

VALID_COMMANDS = ['ride', 'estimate', 'help', 'accept' ]  # Leave out 'products' until user can pick.

# returned when ride isn't requested in the format '{origin} to {destination}'
RIDE_REQUEST_FORMAT_ERROR = <<-STRING
  To request a ride please use the format */uber ride [origin] to [destination]*.
  For best results, specify a city or zip code.
  Ex: */uber ride 1061 Market Street San Francisco to 405 Howard St*
STRING

PRODUCTS_REQUEST_FORMAT_ERROR = <<-STRING
  To see a list of products please use the format */uber products [address]*.
  For best results, specify a city or zip code.
  Ex: */uber products 1061 Market Street San Francisco
STRING

UNKNOWN_COMMAND_ERROR = <<-STRING
  Sorry, we didn't quite catch that command.  Try */uber help* for a list.
STRING

# Products is left out
HELP_TEXT = <<-STRING
  Try these commands:
  - ride [origin address] to [destination address]
  - estimate [origin address] to [destination address]
  - help
STRING

LOCATION_NOT_FOUND_ERROR = "Please enter a valid address. Be as specific as possible (e.g. include city)."

class UberCommand

  def initialize bearer_token, user_id, response_url
    @bearer_token = bearer_token
    @user_id = user_id
    @response_url = response_url
  end

  def run user_input_string
    input = user_input_string.split(" ", 2) # Only split on first space.
    command_name = input.first.downcase

    command_argument = input.second.nil? ? nil : input.second.downcase

    return UNKNOWN_COMMAND_ERROR if invalid_command?(command_name) || command_name.nil?

    response = self.send(command_name, command_argument)
    # Send back response if command is not valid
    return response
  end

  private

  attr_reader :bearer_token

  def estimate user_input_string
    start_addr, end_addr = parse_start_and_end_address(user_input_string)

    start_lat, start_lng = resolve_address(start_addr)
    end_lat, end_lng = resolve_address(end_addr)

    ride_estimate_hash = get_ride_estimate(start_lat, start_lng, end_lat, end_lng)

    format_ride_estimate_response(ride_estimate_hash)
  end

  def help _ # No command argument.
    HELP_TEXT
  end

  def accept _ # No command argument.
    @ride = Ride.where(user_id: @user_id).order(:updated_at).last
    surge_confirmation_id = @ride.surge_confirmation_id
    product_id = @ride.product_id
    start_latitude = @ride.start_latitude
    start_longitude = @ride.start_longitude
    end_latitude = @ride.end_latitude
    end_longitude = @ride.end_longitude

    if (Time.now - @ride.updated_at) > 5.minutes
      # TODO: Break out address resolution in #ride so that we can pass lat/lngs directly.
      start_location = "#{@ride.start_latitude}, #{@ride.start_longitude}"
      end_location = "#{@ride.end_latitude}, #{@ride.end_longitude}"
      return ride "#{start_location} to #{end_location}"
    else
      body = {
        "start_latitude" => start_latitude,
        "start_longitude" => start_longitude,
        "end_latitude" => end_latitude,
        "end_longitude" => end_longitude,
        "surge_confirmation_id" => surge_confirmation_id,
        "product_id" => product_id
      }
      response = RestClient.post(
        "#{BASE_URL}/v1/requests",
        body.to_json,
        authorization: bearer_header,
        "Content-Type" => :json,
        accept: 'json'
      )
      success_msg = format_200_ride_request_response(JSON.parse(response.body))

      reply_to_slack(success_msg)
      ""
    end
  end

  def ride input_str
    origin_name, destination_name = parse_start_and_end_address(input_str)
    origin_lat, origin_lng = resolve_address origin_name
    destination_lat, destination_lng = resolve_address destination_name

    ride_estimate_hash = get_ride_estimate(
      origin_lat,
      origin_lng,
      destination_lat,
      destination_lng
    )

    surge_multiplier = ride_estimate_hash["price"]["surge_multiplier"]
    surge_confirmation_id = ride_estimate_hash["price"]["surge_confirmation_id"]

    ride_attrs = {
      user_id: @user_id,
      :start_latitude => origin_lat,
      :start_longitude => origin_lng,
      :end_latitude => destination_lat,
      :end_longitude => destination_lng,
      :product_id => product_id
    }

    ride_attrs['surge_confirmation_id'] = surge_confirmation_id if surge_confirmation_id

    ride = Ride.create!(ride_attrs)

    if surge_multiplier > 1
      return "#{surge_multiplier} surge is in effect. Reply '/uber accept' to confirm the ride."
    else
      ride_response = request_ride!(start_lat, start_lng, end_lat, end_lng, product_id)
      ride.update!(request_id: ride_response['request_id'])  # TODO: Do async.
      success_msg = format_200_ride_request_response(ride_response)
      reply_to_slack(success_msg)
      ""  # Return empty string in case we answer Slack soon enough for response to go through.
    end
  end

  def request_ride!(start_lat, start_lng, end_lat, end_lng, product_id, surge_confirmation_id = nil)
      body = {
        start_latitude: start_lat,
        start_longitude: start_lng,
        end_latitude: end_lat,
        end_longitude: end_lng,
        product_id: product_id
      }

      body['surge_confirmation_id'] = surge_confirmation_id if surge_confirmation_id

      response = RestClient.post(
        "#{BASE_URL}/v1/requests",
        body.to_json,
        authorization: bearer_header,
        "Content-Type" => :json,
        accept: :json
      )

    JSON.parse(response.body)
  end

  def parse_start_and_end_address(input_str)
    origin_name, destination_name = input_str.split(" to ")

    if origin_name.start_with? "from "
      origin_name = origin_name["from".length..-1]
    end

    [origin_name, destination_name]
  end

  def get_ride_estimate(start_lat, start_lng, end_lat, end_lng)
    available_products = get_products_for_lat_lng(start_lat, start_lng)
    product_id = available_products["products"].first["product_id"]

    body = {
      "start_latitude" => start_lat,
      "start_longitude" => start_lng,
      "end_latitude" => end_lat,
      "end_longitude" => end_lng,
      "product_id" => product_id
    }

    response = RestClient.post(
      "#{BASE_URL}/v1/requests/estimate",
      body.to_json,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: :json
    )

    JSON.parse(response.body)
  end

  def reply_to_slack(response)
      payload = { text: response}

      RestClient.post(@response_url, payload.to_json, "Content-Type" => :json)
  end

  def products address = nil
    if address.blank?
      return PRODUCTS_REQUEST_FORMAT_ERROR
    end

    resolved_add = resolve_address(address)

    if resolved_add == LOCATION_NOT_FOUND_ERROR
      LOCATION_NOT_FOUND_ERROR
    else
      lat, lng = resolved_add
      format_products_response(get_products_for_lat_lng lat, lng)
    end
  end

  def get_products_for_lat_lng lat, lng
    uri = Addressable::URI.parse("#{BASE_URL}/v1/products")
    uri.query_values = { 'latitude' => lat, 'longitude' => lng }
    resource = uri.to_s

    result = RestClient.get(
    resource,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: 'json'
    )

    JSON.parse(result.body)
  end

  def format_200_ride_request_response response
    eta = response['eta'].to_i / 60

    estimate_msg = "very soon" if eta == 0
    estimate_msg = "in 1 minute" if eta == 1
    estimate_msg = "in #{eta} minutes" if eta > 1

    "Thanks! We are looking for a driver and we expect them to arrive #{estimate_msg}."
  end

  def format_response_errors response_errors
    response = "The following errors occurred: \n"
    response_errors.each do |error|
      response += "- *#{error['title']}* \n"
    end
  end

  def format_products_response products_response
    unless products_response['products'] && !products_response['products'].empty?
      return "No Uber products available for that location."
    end
    response = "The following products are available: \n"
    products_response['products'].each do |product|
      response += "- #{product['display_name']}: #{product['description']} (Capacity: #{product['capacity']})\n"
    end
    response
  end

  def format_ride_estimate_response(ride_estimate_hash)
    duration_secs = ride_estimate_hash["trip"]["duration_estimate"]
    duration_mins = duration_secs / 60

    duration_msg = duration_mins == 1 ? "one minute" : "#{duration_mins} minutes"

    cost = ride_estimate_hash["price"]["display"]
    surge = ride_estimate_hash["price"]["surge_multiplier"]
    surge_msg = surge == 1 ? "No surge currently in effect." : "Includes current surge at #{surge_multiplier}."

    ["Let's see... That trip would take about #{duration_msg} and cost #{cost}.", surge_msg].join (" ")
  end

  def bearer_header
    "Bearer #{bearer_token}"
  end

  def invalid_command? name
    !VALID_COMMANDS.include? name
  end

  def resolve_address address
    location = Geocoder.search(address).first

    if location.blank?
      LOCATION_NOT_FOUND_ERROR
    else
      location = location.data["geometry"]["location"]
      [location['lat'], location['lng']]
    end
  end
end