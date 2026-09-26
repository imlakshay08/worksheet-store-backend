require "test_helper"

class SerpApiClientTest < ActiveSupport::TestCase
  # Every test stubs Net::HTTP.start, so nothing here ever reaches serpapi.com
  # or spends a search from the monthly quota.
  def fake_response(klass, code, body)
    response = klass.new("1.1", code, "")
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end

  # Net::HTTP.start is called with a block; a lambda stub stands in for the
  # whole request so the block never runs and no socket is opened.
  def stub_http(response, &block)
    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &_blk) { response }, &block)
  end

  test "returns the parsed payload on success" do
    body = { "organic_results" => [{ "position" => 1, "link" => "https://frenchworksheethub.com/" }] }.to_json

    SerpApiClient.stub(:api_key, "test-key") do
      stub_http(fake_response(Net::HTTPOK, "200", body)) do
        payload = SerpApiClient.search(query: "french worksheets pdf")
        assert_equal 1, payload["organic_results"].first["position"]
      end
    end
  end

  test "raises when no API key is configured" do
    SerpApiClient.stub(:api_key, nil) do
      assert_not SerpApiClient.configured?
      assert_raises(SerpApiClient::NotConfigured) { SerpApiClient.search(query: "anything") }
    end
  end

  test "raises Error on a non-2xx response" do
    SerpApiClient.stub(:api_key, "test-key") do
      stub_http(fake_response(Net::HTTPUnauthorized, "401", '{"error":"Invalid API key"}')) do
        error = assert_raises(SerpApiClient::Error) { SerpApiClient.search(query: "x") }
        assert_match "401", error.message
      end
    end
  end

  test "raises Error when the body carries an error (SerpApi answers 200 for these)" do
    SerpApiClient.stub(:api_key, "test-key") do
      stub_http(fake_response(Net::HTTPOK, "200", '{"error":"Your account has run out of searches."}')) do
        error = assert_raises(SerpApiClient::Error) { SerpApiClient.search(query: "x") }
        assert_match "run out of searches", error.message
      end
    end
  end

  test "raises Error on a connection failure rather than leaking Net::HTTP errors" do
    SerpApiClient.stub(:api_key, "test-key") do
      Net::HTTP.stub(:start, ->(*_args, **_kwargs, &_blk) { raise Net::OpenTimeout }) do
        assert_raises(SerpApiClient::Error) { SerpApiClient.search(query: "x") }
      end
    end
  end
end
