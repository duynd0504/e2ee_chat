/// Login mutation query - Fixed for backend schema
const String loginMutation = r'''
  mutation Login($input: LoginInput!) {
    login(input: $input) {
      success
      data {
        accessToken
        refreshToken
        user {
          id
          username
          email
          phone
        }
      }
    }
  }
''';

/// Register mutation (if needed)
const String registerMutation = r'''
  mutation Register($input: RegisterInput!) {
    register(input: $input) {
      success
      data {
        accessToken
        user {
          id
          username
          email
        }
      }
    }
  }
''';