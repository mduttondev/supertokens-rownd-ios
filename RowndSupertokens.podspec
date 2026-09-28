Pod::Spec.new do |s|
  s.name             = "RowndSupertokens"
  s.module_name      = "Rownd"
  s.version          = "0.2.5"
  s.summary          = "SuperTokens Rownd bindings for iOS"
  s.description      = <<-DESC
                        Rownd is a user management platform designed to make authentication
                        and user lifecycle easy, frictionless, and seamless for both devs and end-users.
                        This SDK integrates Rownd with SuperTokens-backed authentication.
                        DESC
  s.homepage         = "https://github.com/supertokens/supertokens-rownd-ios"
  s.license          = { :type => "Apache 2.0", :file => "LICENSE.txt" }
  s.author           = {
    "SuperTokens" => "support@supertokens.com",
  }
  s.documentation_url = "https://github.com/supertokens/supertokens-rownd-ios"
  s.source            = {
    :git => "https://github.com/supertokens/supertokens-rownd-ios.git",
    :tag => "v#{s.version}"
  }

  s.ios.deployment_target     = '14.0'

  s.dependency 'JWTDecode', '~> 3.0.0'
  s.dependency 'ReSwift', '~> 6.1.1'
  s.dependency 'ReSwiftThunk', '~> 2.0.1'
  s.dependency 'SwiftKeychainWrapper', '~> 4.0.1'
  s.dependency 'Get', '~> 2.2.0'
  s.dependency 'GoogleSignIn', '~> 7.0.0'
  s.dependency 'lottie-ios', '~> 4.5.0'
  s.dependency 'Factory', '~> 1.2.8'
  s.dependency 'SuperTokensIOS', '~> 0.5.4'

  s.dependency 'AnyCodable'
  s.dependency 'GzipSwift'

  s.subspec 'LBBottomSheet' do |ss|
    ss.source_files = 'Packages/LBBottomSheet/Sources/**/*.swift'
    ss.resource_bundles = {
      'RowndLBBottomSheet' => 'Packages/LBBottomSheet/Sources/LBBottomSheet/Resources/**/*'
    }
  end

  s.subspec 'AnyCodable' do |ss|
    ss.source_files = 'Packages/AnyCodable/Sources/**/*'
  end
  
  s.requires_arc     = true
  
  s.source_files     = 'Sources/**/*.swift'
  s.swift_versions   = [ "5.5", "5.4", "5.3", "5.2", "5.0" ]

end
