package dev.muham.fueltriptracker

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the Dart OBD poll loop scheduled while the
 * screen is off or the app is backgrounded.
 *
 * The service itself holds no Bluetooth state; it exists purely so Android
 * stops throttling (and eventually killing) the process mid-drive.
 */
class TripForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopTracking()
            return START_NOT_STICKY
        }

        // A null intent means the system restarted us after a process kill
        // (START_STICKY); fall back to the generic title in that case.
        val profileName = intent
            ?.getStringExtra(EXTRA_PROFILE_NAME)
            ?.takeIf { it.isNotBlank() }

        if (!promoteToForeground(profileName)) {
            stopTracking()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /** Returns true when the service successfully entered the foreground. */
    private fun promoteToForeground(profileName: String?): Boolean {
        return try {
            ensureChannel()
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(profileName),
                type,
            )
            true
        } catch (err: Exception) {
            // API 34 throws SecurityException without the matching permission,
            // API 31+ throws when started from the background. Never crash the
            // host app over it; tracking simply stays in-app only.
            Log.w(TAG, "Unable to start trip foreground service", err)
            false
        }
    }

    private fun stopTracking() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Must run before [ServiceCompat.startForeground] on API 26+, otherwise the
     * notification is dropped and the service is torn down.
     */
    private fun ensureChannel() {
        val channel = NotificationChannelCompat
            .Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(CHANNEL_NAME)
            .setDescription(CHANNEL_DESCRIPTION)
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(this).createNotificationChannel(channel)
    }

    private fun buildNotification(profileName: String?): Notification {
        val text = if (profileName.isNullOrBlank()) {
            DEFAULT_CONTENT_TEXT
        } else {
            "Logging OBD-II data for $profileName"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(NOTIFICATION_TITLE)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(buildContentIntent())
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .build()
    }

    /**
     * Reuses the launcher intent so tapping the notification brings the existing
     * task forward instead of spawning a second one (MainActivity declares an
     * empty taskAffinity, which makes a bare FLAG_ACTIVITY_NEW_TASK unreliable).
     */
    private fun buildContentIntent(): PendingIntent {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        private const val TAG = "TripForegroundService"

        const val ACTION_START = "dev.muham.fueltriptracker.action.START_TRIP"
        const val ACTION_STOP = "dev.muham.fueltriptracker.action.STOP_TRIP"
        const val EXTRA_PROFILE_NAME = "profileName"

        private const val CHANNEL_ID = "trip_tracking"
        private const val CHANNEL_NAME = "Trip tracking"
        private const val CHANNEL_DESCRIPTION =
            "Keeps OBD-II logging alive while a trip is recording."
        private const val NOTIFICATION_ID = 1837
        private const val NOTIFICATION_TITLE = "Trip recording"
        private const val DEFAULT_CONTENT_TEXT = "Logging OBD-II data."

        /**
         * Starts the service. Returns true when the start request was accepted;
         * never throws.
         */
        fun start(context: Context, profileName: String): Boolean {
            val intent = Intent(context, TripForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_PROFILE_NAME, profileName)
            }
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (err: Exception) {
                Log.w(TAG, "startForegroundService rejected", err)
                false
            }
        }

        /** Stops the service. Safe to call when it is not running; never throws. */
        fun stop(context: Context) {
            val intent = Intent(context, TripForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.stopService(intent)
            } catch (err: Exception) {
                Log.w(TAG, "stopService rejected", err)
            }
        }
    }
}
