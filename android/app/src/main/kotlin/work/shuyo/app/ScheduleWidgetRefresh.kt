package work.shuyo.app

import android.app.AlarmManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetScheduler
import java.time.ZonedDateTime

internal object ScheduleWidgetRefresh {
    private const val TAG = "ScheduleWidget"
    private const val KEY_SNAPSHOT = "academic_schedule_widget_snapshot"
    private val providers = listOf(
        ScheduleWidgetSmallProvider(),
        ScheduleWidgetProvider(),
        ScheduleWidgetLargeProvider()
    )

    fun refreshAll(
        context: Context,
        reason: String,
        widgetData: SharedPreferences = HomeWidgetPlugin.getData(context)
    ) {
        val manager = AppWidgetManager.getInstance(context)
        val activeProviders = providers.mapNotNull { provider ->
            val ids = manager.getAppWidgetIds(ComponentName(context, provider.javaClass))
            if (ids.isEmpty()) null else provider to ids
        }
        val schedule = WidgetSchedule.parse(widgetData.getString(KEY_SNAPSHOT, null))
        val now = ZonedDateTime.now()
        for ((provider, ids) in activeProviders) {
            try {
                provider.renderWidgets(context, manager, ids, schedule, now.toLocalDateTime())
            } catch (error: RuntimeException) {
                Log.e(TAG, "Failed to render ${provider.javaClass.simpleName}; reason=$reason", error)
            }
        }

        // A single installed provider owns the alarm and refreshes every size when it fires.
        // Scheduling one alarm per size would compete for the app's idle-alarm quota.
        val alarmOwner = activeProviders.firstOrNull()?.first?.javaClass?.name
            ?.takeIf { schedule != null }
        for (provider in providers) {
            if (provider.javaClass.name != alarmOwner) {
                try {
                    HomeWidgetScheduler.cancel(context, provider.javaClass.name)
                } catch (error: RuntimeException) {
                    Log.e(TAG, "Failed to cancel ${provider.javaClass.simpleName} updates", error)
                }
            }
        }

        if (alarmOwner == null || schedule == null) {
            Log.d(TAG, "Refreshed; reason=$reason renderedAt=$now next=none")
            return
        }

        val next = schedule.nextTransitionAfter(now)
        // If rendering crossed a boundary, refresh shortly instead of dropping the past alarm.
        val triggerAt = maxOf(next.toInstant().toEpochMilli(), System.currentTimeMillis() + 1_000L)
        try {
            // home_widget checks exact-alarm access and falls back to an inexact idle alarm.
            // This is re-armed from each native update, without starting a Flutter engine.
            HomeWidgetScheduler.schedule(context, alarmOwner, listOf(triggerAt))
            val alarmManager = context.getSystemService(AlarmManager::class.java)
            val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                alarmManager?.canScheduleExactAlarms() == true
            Log.d(
                TAG,
                "Refreshed; reason=$reason renderedAt=$now widgets=${activeProviders.sumOf { it.second.size }} " +
                    "next=$triggerAt exact=$exact"
            )
        } catch (error: RuntimeException) {
            // Keep the system's updatePeriodMillis fallback if a launcher/platform rejects scheduling.
            Log.e(TAG, "Failed to schedule the next widget update; reason=$reason next=$triggerAt", error)
        }
    }
}
