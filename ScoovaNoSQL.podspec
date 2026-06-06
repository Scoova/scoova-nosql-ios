Pod::Spec.new do |s|
  s.name             = "ScoovaNoSQL"
  s.version          = "1.0.1"
  s.summary          = "Scoova NoSQL document database client for iOS and macOS."
  s.description      = <<-DESC
                       Swift client for the Scoova NoSQL document database.
                       Firestore-shaped API (collection / document / query /
                       snapshot listeners), backed by Scoova's own
                       multi-tenant platform.
                       DESC
  s.homepage         = "https://cloud.scoo-va.info"
  s.license          = { :type => "MIT" }
  s.author           = { "Scoova" => "admin@scoo-va.info" }

  s.source           = { :git => "https://github.com/Scoova/scoova-nosql-ios.git",
                         :tag => s.version.to_s }
  s.source_files     = "Sources/ScoovaNoSQL/**/*.swift"
  s.swift_versions   = ["5.9"]

  s.ios.deployment_target     = "15.0"
  s.osx.deployment_target     = "12.0"
end
