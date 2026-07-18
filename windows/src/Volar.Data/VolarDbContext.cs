// VolarDbContext.cs — EF Core DbContext, port of TaskStore.swift's ModelContainer/ModelContext
// setup + schema (`Schema([VolarTask.self, CompletionEvent.self, ParseCorrection.self])`) plus
// ReminderRecord (owned by the Reminders module's ModelContainer in Swift, but included here since
// this task's brief asks for all 5 files' persisted shapes in one SQLite database — Volar.Reminders
// will consume this same DbContext rather than standing up a second store).
//
// LIFECYCLE (flagged in the final report per this task's brief, item "Concurrency"): DbContext is
// NOT thread-safe and MUST NOT be used as a shared singleton. This type is deliberately "dumb" — a
// plain DbContext taking already-built DbContextOptions — so composition (how long an instance
// lives, whether it's pooled) is entirely the caller's decision. TaskRepository (this project's
// primary consumer) uses IDbContextFactory<VolarDbContext> and creates a fresh, short-lived context
// per repository call (see TaskRepository.cs), matching the "one DbContext per unit of work"
// guidance the EF Core docs give for exactly this reason.
using Microsoft.EntityFrameworkCore;
using Volar.Data.Converters;
using Volar.Data.Entities;

namespace Volar.Data;

public sealed class VolarDbContext(DbContextOptions<VolarDbContext> options) : DbContext(options)
{
    public DbSet<TaskEntity> Tasks => Set<TaskEntity>();

    public DbSet<ConditionEntity> Conditions => Set<ConditionEntity>();

    public DbSet<ReminderRecordEntity> ReminderRecords => Set<ReminderRecordEntity>();

    public DbSet<CompletionEventEntity> CompletionEvents => Set<CompletionEventEntity>();

    public DbSet<ParseCorrectionEntity> ParseCorrections => Set<ParseCorrectionEntity>();

    /// Applies the UTC-string DateTimeOffset conversion (see Converters/DateTimeOffsetUtcConverters.cs)
    /// to EVERY DateTimeOffset / DateTimeOffset? property in the model, so no individual property
    /// mapping below can accidentally fall back to the Sqlite provider's default handling.
    protected override void ConfigureConventions(ModelConfigurationBuilder configurationBuilder)
    {
        configurationBuilder.Properties<DateTimeOffset>().HaveConversion<DateTimeOffsetToUtcStringConverter>();
        configurationBuilder.Properties<DateTimeOffset?>().HaveConversion<NullableDateTimeOffsetToUtcStringConverter>();
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<TaskEntity>(b =>
        {
            b.HasKey(t => t.Id);
            b.Property(t => t.Title).IsRequired();
            b.Property(t => t.Details).HasDefaultValue("").IsRequired();
            b.Property(t => t.StatusRaw).HasDefaultValue("todo").IsRequired();
            b.Property(t => t.WhenRaw).HasDefaultValue("now").IsRequired();
            b.Property(t => t.KindRaw).HasDefaultValue("task").IsRequired();
            b.Property(t => t.SwitchAwayCount).HasDefaultValue(0);
            b.Property(t => t.IsSensitive).HasDefaultValue(false);

            // Status is a computed, fail-closed projection of StatusRaw — not its own column (mirrors
            // VolarTask.status being a computed accessor over statusRaw, never itself persisted).
            b.Ignore(t => t.Status);

            // Index rationale: ParentId drives TaskRepository's hasChildren/fetchChildren queries
            // (rule 2/rule 5 cascade); StatusRaw + CreatedAt drive FetchAllAsync's ordering and any
            // future "open tasks" filter; mirrors the query patterns TaskStore.swift's
            // FetchDescriptor calls exercise.
            b.HasIndex(t => t.ParentId);
            b.HasIndex(t => t.StatusRaw);
            b.HasIndex(t => t.CreatedAt);

            // Self-referencing breakdown-parent link. ON DELETE SET NULL is a DB-level backstop;
            // TaskRepository.DeleteAsync also nulls children's ParentId explicitly in application
            // code first (matching TaskStore.delete precisely), so this should normally never be the
            // thing that actually fires.
            b.HasOne<TaskEntity>()
                .WithMany()
                .HasForeignKey(t => t.ParentId)
                .OnDelete(DeleteBehavior.SetNull);

            // Normalized condition child table (DESIGN DECISION — see ConditionEntity.cs header).
            // Cascade delete: a task's conditions have no independent lifetime, exactly like the
            // Swift original's single `conditionsData` JSON column being simply gone with the row.
            b.HasMany(t => t.Conditions)
                .WithOne()
                .HasForeignKey(c => c.TaskId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ConditionEntity>(b =>
        {
            b.HasKey(c => c.Id);
            b.Property(c => c.Kind).IsRequired();
            // Enforces "at most one row per (task, position)" and doubles as the query index for
            // ordered reconstruction of a task's Conditions list.
            b.HasIndex(c => new { c.TaskId, c.OrderIndex }).IsUnique();
        });

        modelBuilder.Entity<ReminderRecordEntity>(b =>
        {
            b.HasKey(r => r.Id);
            b.Property(r => r.OffsetKind).IsRequired();
            b.Property(r => r.State).HasDefaultValue("scheduled").IsRequired();
            b.HasIndex(r => r.TaskId);
            b.HasIndex(r => r.FireAt);

            // See ReminderRecordEntity's doc comment: cascade delete is this port's own decision
            // (Swift's TaskStore never manages ReminderRecord lifecycle at all — that's entirely
            // ReminderScheduler's job), flagged for Opus/Reminders-agent confirmation.
            b.HasOne<TaskEntity>()
                .WithMany()
                .HasForeignKey(r => r.TaskId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<CompletionEventEntity>(b =>
        {
            b.HasKey(e => e.Id);
            b.Property(e => e.TitleSnapshot).IsRequired();
            // No relationship configured for TaskId — deliberately dangling by design (see
            // CompletionEventEntity's doc comment). Indexed anyway for potential per-task lookups
            // even though today's ported query surface (events-in-range) filters by CompletedAt.
            b.HasIndex(e => e.TaskId);
            b.HasIndex(e => e.CompletedAt);
            b.HasIndex(e => e.ParentIdSnapshot);
        });

        modelBuilder.Entity<ParseCorrectionEntity>(b =>
        {
            b.HasKey(p => p.Id);
            b.Property(p => p.Attribute).IsRequired();
            b.Property(p => p.ParsedValue).IsRequired();
            b.Property(p => p.CorrectedValue).IsRequired();
            b.Property(p => p.Transcript).IsRequired();
            b.HasIndex(p => p.CreatedAt);
        });
    }
}
