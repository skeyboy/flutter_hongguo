require 'xcodeproj'
project = Xcodeproj::Project.open(File.expand_path('../../packages/app/ios/Runner.xcodeproj', __dir__))
project.targets.select { |target| target.name == 'Runner' }.each do |target|
  target.build_configurations.each do |config|
    config.build_settings['DEVELOPMENT_TEAM'] = ENV.fetch('IOS_TEAM_ID')
    config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
    config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Distribution'
    config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = ENV.fetch('IOS_PROFILE_NAME')
  end
end
project.save
