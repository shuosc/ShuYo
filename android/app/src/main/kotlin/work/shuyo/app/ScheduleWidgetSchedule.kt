package work.shuyo.app

import android.util.Log
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.Locale

internal data class WidgetSchedule(
    val term: String,
    val maxWeek: Int,
    val currentWeek: Int,
    val anchorMonday: String,
    val courses: List<WidgetCourse>
) {
    fun activeWeek(today: LocalDate): Int {
        val vacationWeek = maxWeek + 1
        val anchor = parseDate(anchorMonday)
            ?: return currentWeek.coerceIn(0, vacationWeek)
        val todayMonday = today.minusDays((today.dayOfWeek.value - 1).toLong())
        val weekOffset = ChronoUnit.WEEKS.between(anchor, todayMonday).toInt()
        return (currentWeek + weekOffset).coerceIn(0, vacationWeek.coerceAtLeast(2))
    }

    fun coursesOn(day: LocalDate): List<WidgetCourse> {
        val week = activeWeek(day)
        if (week !in 1..maxWeek) {
            return emptyList()
        }
        return courses
            .filter { it.weekday == day.dayOfWeek.value && it.occursInWeek(week) }
            .sortedWith(compareBy<WidgetCourse> { it.startMinute }.thenBy { it.name })
    }

    fun nextTransitionAfter(now: ZonedDateTime): ZonedDateTime {
        val today = now.toLocalDate()
        // Midnight updates the day/week and continues the chain even on days without courses.
        var next = today.plusDays(1).atStartOfDay(now.zone)
        for (course in coursesOn(today)) {
            for (minute in listOf(course.startMinute, course.endMinute)) {
                val transition = today.atStartOfDay().plusMinutes(minute.toLong()).atZone(now.zone)
                if (transition.isAfter(now) && transition.isBefore(next)) {
                    next = transition
                }
            }
        }
        return next
    }

    companion object {
        fun parse(raw: String?): WidgetSchedule? {
            if (raw.isNullOrBlank()) {
                return null
            }
            return try {
                val json = JSONObject(raw)
                if (!json.optBoolean("hasSchedule", false)) {
                    return null
                }
                val sessions = mutableListOf<WidgetCourse>()
                val sessionJson = json.optJSONArray("sessions")
                if (sessionJson != null) {
                    for (index in 0 until sessionJson.length()) {
                        val course = WidgetCourse.parse(
                            sessionJson.optJSONObject(index) ?: continue
                        )
                        if (course != null) {
                            sessions.add(course)
                        }
                    }
                }
                WidgetSchedule(
                    term = json.optString("term", ""),
                    maxWeek = json.optInt("maxWeek", 1).coerceAtLeast(1),
                    currentWeek = json.optInt("currentWeek", 1).coerceAtLeast(0),
                    anchorMonday = json.optString("anchorMonday", ""),
                    courses = sessions
                )
            } catch (error: Exception) {
                Log.w("ScheduleWidget", "Failed to parse the cached widget schedule", error)
                null
            }
        }
    }
}

internal data class WidgetCourse(
    val name: String,
    val room: String,
    val meta: String,
    val weekday: Int,
    val weeks: Set<Int>,
    val startMinute: Int,
    val endMinute: Int,
    val startText: String,
    val endText: String,
    val sectionText: String
) {
    fun occursInWeek(week: Int): Boolean = weeks.isEmpty() || weeks.contains(week)

    fun hasNotEnded(minute: Int): Boolean = minute < endMinute

    fun isActive(minute: Int): Boolean = minute >= startMinute && hasNotEnded(minute)

    companion object {
        fun parse(json: JSONObject): WidgetCourse? {
            val name = json.optString("name", "").trim()
            val weekday = json.optInt("weekday", 0)
            val startMinute = json.optInt("startMinute", -1)
            val endMinute = json.optInt("endMinute", -1)
            if (name.isBlank() ||
                weekday !in 1..7 ||
                startMinute !in 0 until 24 * 60 ||
                endMinute !in 1..24 * 60 ||
                endMinute <= startMinute
            ) {
                return null
            }

            val weeks = mutableSetOf<Int>()
            val weekJson = json.optJSONArray("weeks")
            if (weekJson != null) {
                for (index in 0 until weekJson.length()) {
                    val week = weekJson.optInt(index, 0)
                    if (week > 0) {
                        weeks.add(week)
                    }
                }
            }

            return WidgetCourse(
                name = name,
                room = json.optString("room", "").trim(),
                meta = json.optString("meta", "").trim(),
                weekday = weekday,
                weeks = weeks,
                startMinute = startMinute,
                endMinute = endMinute,
                startText = json.optString("startText", formatMinute(startMinute)),
                endText = json.optString("endText", formatMinute(endMinute)),
                sectionText = json.optString("sectionText", "").trim()
            )
        }

        private fun formatMinute(minute: Int): String {
            return String.format(
                Locale.US,
                "%02d:%02d",
                minute / 60,
                minute % 60
            )
        }
    }
}

private fun parseDate(value: String): LocalDate? {
    val datePart = value.substringBefore("T").ifBlank { return null }
    return try {
        LocalDate.parse(datePart)
    } catch (_: Exception) {
        null
    }
}
