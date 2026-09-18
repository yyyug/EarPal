platform :ios, '27.0'

target 'EarPal' do
  use_frameworks!

  pod 'MediaPipeTasksGenAI'
  pod 'MediaPipeTasksGenAIC'
  pod 'ZIPFoundation', '~> 0.9'
  pod 'GRDB.swift', git: 'https://github.com/groue/GRDB.swift.git', tag: 'v7.11.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
