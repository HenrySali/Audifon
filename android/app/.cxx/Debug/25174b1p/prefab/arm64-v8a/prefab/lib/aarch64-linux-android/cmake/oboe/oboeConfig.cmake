if(NOT TARGET oboe::oboe)
add_library(oboe::oboe SHARED IMPORTED)
set_target_properties(oboe::oboe PROPERTIES
    IMPORTED_LOCATION "C:/Users/Elsa y Henry/.gradle/caches/transforms-4/b8c189f3f8f96ad4968c5b4cc2bd876d/transformed/jetified-oboe-1.9.0/prefab/modules/oboe/libs/android.arm64-v8a/liboboe.so"
    INTERFACE_INCLUDE_DIRECTORIES "C:/Users/Elsa y Henry/.gradle/caches/transforms-4/b8c189f3f8f96ad4968c5b4cc2bd876d/transformed/jetified-oboe-1.9.0/prefab/modules/oboe/include"
    INTERFACE_LINK_LIBRARIES ""
)
endif()

