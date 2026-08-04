package dev.muham.fueltriptracker

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var tripServiceChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TRIP_SERVICE_CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startTripService" -> {
                    val profileName = call.argument<String>("profileName").orEmpty()
                    result.success(
                        TripForegroundService.start(applicationContext, profileName),
                    )
                }

                "stopTripService" -> {
                    TripForegroundService.stop(applicationContext)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        tripServiceChannel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        tripServiceChannel?.setMethodCallHandler(null)
        tripServiceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private const val TRIP_SERVICE_CHANNEL = "dev.muham.fueltriptracker/trip_service"
    }
}
