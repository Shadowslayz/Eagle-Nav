# SnakeYAML on Android: java.beans does not exist on Android runtime.
-dontwarn java.beans.**
-dontwarn org.yaml.snakeyaml.**

# Keep SnakeYAML metadata/introspection classes that may be reflectively referenced.
-keep class org.yaml.snakeyaml.** { *; }