package work.shuyo.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

class ScheduleWidgetScheduleTest {
    private val zone = ZoneId.of("Asia/Shanghai")

    @Test
    fun courseStartsInclusivelyAndEndsExclusively() {
        val course = course()

        assertFalse(course.isActive(7 * 60 + 59))
        assertTrue(course.isActive(8 * 60))
        assertTrue(course.isActive(9 * 60 + 39))
        assertFalse(course.isActive(9 * 60 + 40))
        assertFalse(course.hasNotEnded(9 * 60 + 40))
        assertFalse(course.hasNotEnded(9 * 60 + 41))
    }

    @Test
    fun nextTransitionTracksStartsAndEndsWithoutReplayingPastBoundaries() {
        val schedule = schedule(course())
        val cases = listOf(
            "2026-11-09T07:59:59" to "2026-11-09T08:00:00",
            "2026-11-09T08:00:00" to "2026-11-09T09:40:00",
            "2026-11-09T08:17:00" to "2026-11-09T09:40:00",
            "2026-11-09T09:39:59" to "2026-11-09T09:40:00",
            "2026-11-09T09:40:00" to "2026-11-10T00:00:00",
            "2026-11-09T15:00:00" to "2026-11-10T00:00:00"
        )

        for ((now, expected) in cases) {
            assertEquals(now, at(expected), schedule.nextTransitionAfter(at(now)))
        }
    }

    @Test
    fun aLateAlarmCatchesUpUsingTheCurrentTime() {
        val schedule = schedule(course(), course(start = 10 * 60, end = 11 * 60 + 40))

        assertEquals(
            at("2026-11-09T10:00:00"),
            schedule.nextTransitionAfter(at("2026-11-09T09:55:00"))
        )
        assertEquals(
            at("2026-11-09T11:40:00"),
            schedule.nextTransitionAfter(at("2026-11-09T10:15:00"))
        )
    }

    @Test
    fun adjacentCoursesSwitchAtTheirSharedBoundary() {
        val first = course()
        val second = course(start = first.endMinute, end = 11 * 60 + 40)
        val schedule = schedule(first, second)

        assertFalse(first.isActive(first.endMinute))
        assertTrue(second.isActive(first.endMinute))
        assertEquals(
            at("2026-11-09T11:40:00"),
            schedule.nextTransitionAfter(at("2026-11-09T09:40:00"))
        )
    }

    @Test
    fun overlappingCoursesUseTheEarliestFutureBoundary() {
        val schedule = schedule(course(), course(start = 9 * 60, end = 10 * 60))

        assertEquals(
            at("2026-11-09T09:00:00"),
            schedule.nextTransitionAfter(at("2026-11-09T08:55:00"))
        )
        assertEquals(
            at("2026-11-09T09:40:00"),
            schedule.nextTransitionAfter(at("2026-11-09T09:00:00"))
        )
    }

    @Test
    fun coursesOnOtherWeekdaysOrTeachingWeeksDoNotScheduleClassAlarms() {
        val schedule = schedule(course(weekday = 2), course(weeks = setOf(2)))

        assertTrue(schedule.coursesOn(LocalDate.of(2026, 11, 9)).isEmpty())
        assertEquals(
            at("2026-11-10T00:00:00"),
            schedule.nextTransitionAfter(at("2026-11-09T07:00:00"))
        )
    }

    @Test
    fun aNewTeachingWeekUsesItsOwnCourseOccurrences() {
        val schedule = schedule(course(weeks = setOf(2)))

        assertEquals(2, schedule.activeWeek(LocalDate.of(2026, 11, 16)))
        assertEquals(
            at("2026-11-16T08:00:00"),
            schedule.nextTransitionAfter(at("2026-11-16T07:00:00"))
        )
    }

    @Test
    fun midnightKeepsTheChainAliveWithoutCoursesAndAcrossWeekChanges() {
        for (schedule in listOf(schedule(), schedule(course()))) {
            assertEquals(
                at("2026-11-10T00:00:00"),
                schedule.nextTransitionAfter(at("2026-11-09T23:59:59"))
            )
            assertEquals(
                at("2026-11-16T00:00:00"),
                schedule.nextTransitionAfter(at("2026-11-15T23:59:59"))
            )
        }
    }

    @Test
    fun vacationsScheduleMidnightInsteadOfCourseBoundaries() {
        val schedule = schedule(course(weeks = emptySet()))

        assertTrue(schedule.coursesOn(LocalDate.of(2026, 11, 2)).isEmpty())
        assertTrue(schedule.coursesOn(LocalDate.of(2027, 3, 8)).isEmpty())
        assertEquals(
            at("2026-11-03T00:00:00"),
            schedule.nextTransitionAfter(at("2026-11-02T07:00:00"))
        )
    }

    @Test
    fun midnightUsesCalendarDaysAcrossDaylightSavingChanges() {
        val now = at("2026-03-08T00:30:00", ZoneId.of("America/New_York"))
        val next = schedule().nextTransitionAfter(now)

        assertEquals(at("2026-03-09T00:00:00", now.zone), next)
        assertEquals(Duration.ofHours(22).plusMinutes(30), Duration.between(now, next))
    }

    @Test
    fun recomputingAfterATimezoneChangePreservesLocalClassTimes() {
        val schedule = schedule(course())
        val shanghai = schedule.nextTransitionAfter(at("2026-11-09T07:00:00"))
        val newYork = schedule.nextTransitionAfter(
            at("2026-11-09T07:00:00", ZoneId.of("America/New_York"))
        )

        assertEquals(shanghai.toLocalDateTime(), newYork.toLocalDateTime())
        assertNotEquals(shanghai.toInstant(), newYork.toInstant())
    }

    private fun at(value: String, zone: ZoneId = this.zone): ZonedDateTime =
        LocalDateTime.parse(value).atZone(zone)

    private fun schedule(vararg courses: WidgetCourse): WidgetSchedule = WidgetSchedule(
        term = "Test term",
        maxWeek = 16,
        currentWeek = 1,
        anchorMonday = "2026-11-09T00:00:00",
        courses = courses.toList()
    )

    private fun course(
        start: Int = 8 * 60,
        end: Int = 9 * 60 + 40,
        weekday: Int = 1,
        weeks: Set<Int> = setOf(1)
    ): WidgetCourse = WidgetCourse(
        name = "Test course",
        room = "",
        meta = "",
        weekday = weekday,
        weeks = weeks,
        startMinute = start,
        endMinute = end,
        startText = "08:00",
        endText = "09:40",
        sectionText = ""
    )
}
