using Volar.Core;
using Xunit;
using static Volar.Core.Tests.Fixtures;

namespace Volar.Core.Tests;

/// <summary>
/// Coverage for <see cref="ConflictChecker.Conflicts"/> (phase4-contract.md §C, spec.md FR-011c):
/// one positive + one low-noise near-miss negative per conflict kind, plus the structural
/// guarantees (empty snapshot, no-deadline candidate, busy-interval contribution to capacity, the
/// duplicate-score boundary, and determinism under snapshot shuffle).
/// </summary>
public class ConflictCheckTests
{
    // MARK: - Structural

    [Fact]
    public void EmptySnapshotReturnsNoConflicts()
    {
        var candidate = MakeTask(
            id: FixedGuid(1), title: "Ship the release", priority: 1, deadline: Tomorrow(),
            estimateMinutes: 60);

        var result = ConflictChecker.Conflicts(
            candidate, [], ReferenceNow, TestTimeZone, [], null);

        Assert.Empty(result);
    }

    [Fact]
    public void NoDeadlineCandidateIsSafe()
    {
        var candidate = MakeTask(id: FixedGuid(1), title: "Water the plants", priority: null, deadline: null);
        var unrelated = MakeTask(id: FixedGuid(2), title: "Finish the quarterly report", deadline: Tomorrow());
        var frog = MakeTask(id: FixedGuid(3), title: "Ship the release", priority: 1, deadline: TodayLater());

        var result = ConflictChecker.Conflicts(
            candidate, [unrelated, frog], ReferenceNow, TestTimeZone, [], frog.Id);

        Assert.Empty(result);
    }

    // MARK: - deadlineCapacity

    [Fact]
    public void DeadlineCapacityFiresWhenDayIsOvercommitted()
    {
        var day = Tomorrow();
        TaskSnapshot[] existing =
        [
            MakeTask(id: FixedGuid(1), title: "A", deadline: day, estimateMinutes: 100),
            MakeTask(id: FixedGuid(2), title: "B", deadline: day, estimateMinutes: 100),
            MakeTask(id: FixedGuid(3), title: "C", deadline: day, estimateMinutes: 100),
        ];
        var candidate = MakeTask(id: FixedGuid(4), title: "D", deadline: day, estimateMinutes: 100);

        var result = ConflictChecker.Conflicts(
            candidate, existing, ReferenceNow, TestTimeZone, [], null);

        var dayEnd = StartOfDayUtc(day).AddDays(1);
        Assert.Contains(new TaskConflict.DeadlineCapacity(3, 400, dayEnd), result);
    }

    [Fact]
    public void DeadlineCapacityNearMissDoesNotFire()
    {
        var day = Tomorrow();
        TaskSnapshot[] existing =
        [
            MakeTask(id: FixedGuid(1), title: "A", deadline: day, estimateMinutes: 50),
            MakeTask(id: FixedGuid(2), title: "B", deadline: day, estimateMinutes: 50),
        ];
        var candidate = MakeTask(id: FixedGuid(3), title: "C", deadline: day, estimateMinutes: 50);

        var result = ConflictChecker.Conflicts(
            candidate, existing, ReferenceNow, TestTimeZone, [], null);

        Assert.DoesNotContain(result, c => c is TaskConflict.DeadlineCapacity);
    }

    [Fact]
    public void DeadlineCapacityIncludesBusyIntervals()
    {
        var day = Tomorrow();
        var dayStart = StartOfDayUtc(day);
        TaskSnapshot[] existing = [MakeTask(id: FixedGuid(1), title: "A", deadline: day, estimateMinutes: 100)];
        var candidate = MakeTask(id: FixedGuid(2), title: "B", deadline: day, estimateMinutes: 110);

        // 3 busy hours (180 min) fully inside the deadline day: 100 + 180 + 110 = 390 >= 384.
        var busy = new DateInterval(dayStart.AddHours(2), dayStart.AddHours(5));

        var result = ConflictChecker.Conflicts(
            candidate, existing, ReferenceNow, TestTimeZone, [busy], null);

        var dayEnd = dayStart.AddDays(1);
        Assert.Contains(new TaskConflict.DeadlineCapacity(1, 390, dayEnd), result);
    }

    // MARK: - deadlineCollision

    [Fact]
    public void DeadlineCollisionFiresAgainstInProgressTask()
    {
        var existingDeadline = TodayLater(14);
        var existing = MakeTask(id: FixedGuid(1), title: "Prep the demo", status: TaskState.InProgress, deadline: existingDeadline);
        var candidate = MakeTask(
            id: FixedGuid(2), title: "Send the follow-up",
            deadline: existingDeadline.AddMinutes(30));

        var result = ConflictChecker.Conflicts(
            candidate, [existing], ReferenceNow, TestTimeZone, [], null);

        Assert.Contains(new TaskConflict.DeadlineCollision(existing.Id, existing.Title), result);
    }

    [Fact]
    public void DeadlineCollisionNearMissAgainstPlainTodoDoesNotFire()
    {
        var existingDeadline = TodayLater(14);
        // Ordinary to-do, no priority, not the frog: not "urgent" per the contract, so no signal
        // even though the deadlines are close.
        var existing = MakeTask(id: FixedGuid(1), title: "Read an article", status: TaskState.Todo, priority: null, deadline: existingDeadline);
        var candidate = MakeTask(
            id: FixedGuid(2), title: "Send the follow-up",
            deadline: existingDeadline.AddMinutes(30));

        var result = ConflictChecker.Conflicts(
            candidate, [existing], ReferenceNow, TestTimeZone, [], null);

        Assert.DoesNotContain(result, c => c is TaskConflict.DeadlineCollision);
    }

    [Fact]
    public void DeadlineCollisionOutsideWindowDoesNotFire()
    {
        var existingDeadline = TodayLater(9);
        var existing = MakeTask(id: FixedGuid(1), title: "Prep the demo", status: TaskState.InProgress, deadline: existingDeadline);
        // 3 hours away: outside the 2-hour collision window.
        var candidate = MakeTask(
            id: FixedGuid(2), title: "Send the follow-up",
            deadline: existingDeadline.AddHours(3));

        var result = ConflictChecker.Conflicts(
            candidate, [existing], ReferenceNow, TestTimeZone, [], null);

        Assert.DoesNotContain(result, c => c is TaskConflict.DeadlineCollision);
    }

    // MARK: - dependsOnBlocked

    [Fact]
    public void DependsOnBlockedFiresForOverdueReference()
    {
        var blocker = MakeTask(id: FixedGuid(1), title: "Get sign-off", status: TaskState.Todo, deadline: Yesterday());
        var candidate = MakeTask(id: FixedGuid(2), title: "Ship the feature", conditions: [new TaskDoneCondition(blocker.Id)]);

        var result = ConflictChecker.Conflicts(
            candidate, [blocker], ReferenceNow, TestTimeZone, [], null);

        Assert.Contains(new TaskConflict.DependsOnBlocked(blocker.Id, blocker.Title), result);
    }

    [Fact]
    public void DependsOnBlockedFiresForStuckReference()
    {
        var blocker = MakeTask(
            id: FixedGuid(1), title: "Get sign-off", status: TaskState.Todo, deadline: null,
            conditions: [new ExternalCondition("waiting on legal", false)]);
        var candidate = MakeTask(id: FixedGuid(2), title: "Ship the feature", conditions: [new TaskDoneCondition(blocker.Id)]);

        var result = ConflictChecker.Conflicts(
            candidate, [blocker], ReferenceNow, TestTimeZone, [], null);

        Assert.Contains(new TaskConflict.DependsOnBlocked(blocker.Id, blocker.Title), result);
    }

    [Fact]
    public void DependsOnBlockedNearMissDoesNotFire()
    {
        var blocker = MakeTask(id: FixedGuid(1), title: "Get sign-off", status: TaskState.Todo, deadline: Tomorrow());
        var candidate = MakeTask(id: FixedGuid(2), title: "Ship the feature", conditions: [new TaskDoneCondition(blocker.Id)]);

        var result = ConflictChecker.Conflicts(
            candidate, [blocker], ReferenceNow, TestTimeZone, [], null);

        Assert.DoesNotContain(result, c => c is TaskConflict.DependsOnBlocked);
    }

    [Fact]
    public void DependsOnBlockedDoneReferenceDoesNotFire()
    {
        var blocker = MakeTask(id: FixedGuid(1), title: "Get sign-off", status: TaskState.Done, deadline: Yesterday());
        var candidate = MakeTask(id: FixedGuid(2), title: "Ship the feature", conditions: [new TaskDoneCondition(blocker.Id)]);

        var result = ConflictChecker.Conflicts(
            candidate, [blocker], ReferenceNow, TestTimeZone, [], null);

        Assert.DoesNotContain(result, c => c is TaskConflict.DependsOnBlocked);
    }

    // MARK: - competesWithFrog

    [Fact]
    public void CompetesWithFrogFiresForPriorityOneCandidate()
    {
        var frog = MakeTask(id: FixedGuid(1), title: "Today's most important thing", status: TaskState.InProgress);
        var candidate = MakeTask(id: FixedGuid(2), title: "A different urgent thing", priority: 1);

        var result = ConflictChecker.Conflicts(
            candidate, [frog], ReferenceNow, TestTimeZone, [], frog.Id);

        Assert.Contains(new TaskConflict.CompetesWithFrog(frog.Id, frog.Title), result);
    }

    [Fact]
    public void CompetesWithFrogNearMissDoesNotFire()
    {
        var frog = MakeTask(id: FixedGuid(1), title: "Today's most important thing", status: TaskState.InProgress);
        var candidate = MakeTask(id: FixedGuid(2), title: "Something for later", priority: 3, deadline: Tomorrow());

        var result = ConflictChecker.Conflicts(
            candidate, [frog], ReferenceNow, TestTimeZone, [], frog.Id);

        Assert.DoesNotContain(result, c => c is TaskConflict.CompetesWithFrog);
    }

    [Fact]
    public void CompetesWithFrogSelfDoesNotFire()
    {
        var candidate = MakeTask(id: FixedGuid(1), title: "Today's most important thing", priority: 1);

        var result = ConflictChecker.Conflicts(
            candidate, [], ReferenceNow, TestTimeZone, [], candidate.Id);

        Assert.DoesNotContain(result, c => c is TaskConflict.CompetesWithFrog);
    }

    // MARK: - possibleDuplicate

    [Fact]
    public void PossibleDuplicateFiresForDiacriticAndCaseVariant()
    {
        var existing = MakeTask(id: FixedGuid(1), title: "Đọc sách buổi tối", status: TaskState.Todo);
        var candidate = MakeTask(id: FixedGuid(2), title: "doc sach buoi toi");

        var result = ConflictChecker.Conflicts(
            candidate, [existing], ReferenceNow, TestTimeZone, [], null);

        var duplicate = Assert.IsType<TaskConflict.PossibleDuplicate>(
            Assert.Single(result, c => c is TaskConflict.PossibleDuplicate));
        Assert.Equal(existing.Id, duplicate.TaskId);
        Assert.Equal(existing.Title, duplicate.Title);
        Assert.Equal(1.0, duplicate.Score);
    }

    [Fact]
    public void PossibleDuplicateNearMissDoesNotFire()
    {
        var existing = MakeTask(id: FixedGuid(1), title: "Buy groceries for the week", status: TaskState.Todo);
        var candidate = MakeTask(id: FixedGuid(2), title: "File the quarterly tax return");

        var result = ConflictChecker.Conflicts(
            candidate, [existing], ReferenceNow, TestTimeZone, [], null);

        Assert.DoesNotContain(result, c => c is TaskConflict.PossibleDuplicate);
    }

    [Fact]
    public void PossibleDuplicateThresholdBoundary()
    {
        // candidate {one, two, three, four}; at-threshold {one, two, three, four, five}:
        // intersection 4 / union 5 = 0.8 -> fires.
        var atThreshold = MakeTask(id: FixedGuid(1), title: "one two three four five", status: TaskState.Todo);
        var candidateAt = MakeTask(id: FixedGuid(2), title: "one two three four");

        var atResult = ConflictChecker.Conflicts(
            candidateAt, [atThreshold], ReferenceNow, TestTimeZone, [], null);
        Assert.Contains(atResult, c => c is TaskConflict.PossibleDuplicate d && d.TaskId == atThreshold.Id && d.Score == 0.8);

        // candidate {one, two, three, four}; just-below {one, two, three}:
        // intersection 3 / union 4 = 0.75 -> does not fire.
        var belowThreshold = MakeTask(id: FixedGuid(3), title: "one two three", status: TaskState.Todo);
        var candidateBelow = MakeTask(id: FixedGuid(4), title: "one two three four");

        var belowResult = ConflictChecker.Conflicts(
            candidateBelow, [belowThreshold], ReferenceNow, TestTimeZone, [], null);
        Assert.DoesNotContain(belowResult, c => c is TaskConflict.PossibleDuplicate);
    }

    // MARK: - Determinism

    [Fact]
    public void DeterminismUnderSnapshotShuffle()
    {
        var day = Tomorrow();
        var capacityA = MakeTask(id: FixedGuid(1), title: "Cap A", deadline: day, estimateMinutes: 200);
        var capacityB = MakeTask(id: FixedGuid(2), title: "Cap B", deadline: day, estimateMinutes: 200);
        var collisionSource = MakeTask(id: FixedGuid(3), title: "Urgent demo", status: TaskState.InProgress, deadline: TodayLater(14));
        var blocker = MakeTask(id: FixedGuid(4), title: "Get sign-off", status: TaskState.Todo, deadline: Yesterday());
        var frog = MakeTask(id: FixedGuid(5), title: "Frog task", status: TaskState.InProgress);
        var duplicateSource = MakeTask(id: FixedGuid(6), title: "Ship the release", status: TaskState.Todo);

        TaskSnapshot[] snapshot = [capacityA, capacityB, collisionSource, blocker, frog, duplicateSource];
        TaskSnapshot[] shuffled = [duplicateSource, frog, blocker, collisionSource, capacityB, capacityA];

        var candidate = MakeTask(
            id: FixedGuid(7), title: "Ship the release", priority: 1, deadline: day,
            conditions: [new TaskDoneCondition(blocker.Id)], estimateMinutes: 100);

        var resultInOrder = ConflictChecker.Conflicts(
            candidate, snapshot, ReferenceNow, TestTimeZone, [], frog.Id);
        var resultShuffled = ConflictChecker.Conflicts(
            candidate, shuffled, ReferenceNow, TestTimeZone, [], frog.Id);

        Assert.Equal(resultInOrder, resultShuffled);
        Assert.NotEmpty(resultInOrder);
    }

    // MARK: - Adversarial robustness

    [Fact]
    public void AdversarialSnapshotIsBoundedAndSafe()
    {
        var day = Tomorrow();
        var sharedId = FixedGuid(1);
        var hugeA = MakeTask(id: sharedId, title: "Huge A", deadline: day, estimateMinutes: int.MaxValue);
        var hugeB = MakeTask(id: sharedId, title: "Huge B", deadline: day, estimateMinutes: int.MaxValue);
        var negative = MakeTask(id: FixedGuid(2), title: "Negative", deadline: day, estimateMinutes: -999);
        var candidate = MakeTask(id: FixedGuid(3), title: "Candidate", deadline: day, estimateMinutes: int.MaxValue);

        var result = ConflictChecker.Conflicts(
            candidate, [hugeA, hugeB, negative], ReferenceNow, TestTimeZone, [], null);

        // The point of this test is simply that the call above returns instead of crashing or
        // hanging; a capacity conflict is expected (the day is trivially over capacity), but
        // asserting non-empty here also proves clamping didn't silently zero everything out.
        Assert.Contains(result, c => c is TaskConflict.DeadlineCapacity);
    }

    // MARK: - Test-local helper

    /// <summary>
    /// UTC start-of-day for <paramref name="instant"/>, used only to build expected
    /// <c>WindowEnd</c> values in assertions. Mirrors <see cref="TestTimeZone"/> being UTC in every
    /// test in this file — production code computes this via the injected <see cref="TimeZoneInfo"/>
    /// (see <c>ConflictChecker</c>'s private <c>StartOfDay</c>), never <see cref="TimeZoneInfo.Local"/>.
    /// </summary>
    private static DateTimeOffset StartOfDayUtc(DateTimeOffset instant) =>
        new(instant.Year, instant.Month, instant.Day, 0, 0, 0, TimeSpan.Zero);
}
