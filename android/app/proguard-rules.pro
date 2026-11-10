# kotlinx.serialization: keep generated serializers for the editor schema.
-keepclassmembers class com.guilhermeramalho.puriotv.core.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.guilhermeramalho.puriotv.core.**$$serializer { *; }
