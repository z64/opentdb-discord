module OpenTDB
  class Session
    attr_reader :token

    def initialize(token = nil)
      @token = token || API.token
    end

    def reset
      API.reset token
    end

    def questions(amount, type: nil, difficulty: nil, category: nil)
      API.questions(
        amount,
        token,
        type,
        difficulty,
        category
      )[:results]
    end
  end

  module API
    API_URL = %q{https://opentdb.com}

    module_function

    def get(route = %{}, params = {})
      response = RestClient.get %Q{#{API_URL}/#{route}}, params: params
      JSON.parse response, symbolize_names: true
    end

    def questions(amount = nil, token = nil, type = nil, difficulty = nil, category = nil)
      get(%{api.php}, {
        amount: amount,
        token: token,
        type: type,
        difficulty: difficulty,
        category: category
      }.compact)
    end

    def token
      get(%{api_token.php}, { command: %{request} })[:token]
    end

    def reset(token)
      get(%{api_token.php}, { command: %{reset}, token: token })
    end
  end
end
