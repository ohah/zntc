package com.exampleapp

import android.app.Application
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost

class MainApplication : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    // In Release mode, always use bundle from assets (Bungae bundle)
    // In Debug mode, check if Bungae bundle exists in assets first
    val useBungaeBundle = shouldUseBungaeBundle()
    
    getDefaultReactHost(
      context = applicationContext,
      packageList =
        PackageList(this).packages.apply {
          // Packages that cannot be autolinked yet can be added manually here, for example:
          // add(MyReactNativePackage())
        },
      jsBundleFilePath = null, // null = use assets bundle (Bungae bundle if available)
    )
  }

  override fun onCreate() {
    super.onCreate()
    loadReactNative(this)
  }

  /**
   * Check if Bungae bundle should be used
   * In Release mode, always use assets bundle (Bungae bundle)
   * In Debug mode, prefer assets bundle if available, otherwise use Metro dev server
   */
  private fun shouldUseBungaeBundle(): Boolean {
    val bundleFileName = "index.android.bundle"
    
    // Check if bundle exists in assets (bundled in APK)
    // If Bungae bundle was copied to android/app/src/main/assets/index.android.bundle
    // during Gradle build, it will be available in assets
    try {
      val inputStream = assets.open(bundleFileName)
      inputStream.close()
      // Bundle exists in assets (Bungae bundle)
      // getDefaultReactHost with jsBundleFilePath=null will load from assets
      return true
    } catch (e: Exception) {
      // Bundle not found in assets
      // In Release mode, this should not happen (build should fail)
      // In Debug mode, will fall back to Metro dev server
      return false
    }
  }
}
