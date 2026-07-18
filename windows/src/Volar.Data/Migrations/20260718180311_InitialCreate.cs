using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Volar.Data.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "CompletionEvents",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    TaskId = table.Column<Guid>(type: "TEXT", nullable: false),
                    TitleSnapshot = table.Column<string>(type: "TEXT", nullable: false),
                    ParentIdSnapshot = table.Column<Guid>(type: "TEXT", nullable: true),
                    EstimateSnapshot = table.Column<int>(type: "INTEGER", nullable: true),
                    CompletedAt = table.Column<string>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_CompletionEvents", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "ParseCorrections",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Attribute = table.Column<string>(type: "TEXT", nullable: false),
                    ParsedValue = table.Column<string>(type: "TEXT", nullable: false),
                    CorrectedValue = table.Column<string>(type: "TEXT", nullable: false),
                    Transcript = table.Column<string>(type: "TEXT", nullable: false),
                    CreatedAt = table.Column<string>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ParseCorrections", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "Tasks",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Title = table.Column<string>(type: "TEXT", nullable: false),
                    Details = table.Column<string>(type: "TEXT", nullable: false, defaultValue: ""),
                    PriorityRaw = table.Column<int>(type: "INTEGER", nullable: false),
                    StatusRaw = table.Column<string>(type: "TEXT", nullable: false, defaultValue: "todo"),
                    Deadline = table.Column<string>(type: "TEXT", nullable: true),
                    CreatedAt = table.Column<string>(type: "TEXT", nullable: false),
                    WhenRaw = table.Column<string>(type: "TEXT", nullable: false, defaultValue: "now"),
                    DurationMinutes = table.Column<int>(type: "INTEGER", nullable: true),
                    Frog = table.Column<bool>(type: "INTEGER", nullable: false),
                    Notes = table.Column<string>(type: "TEXT", nullable: true),
                    SourceTranscript = table.Column<string>(type: "TEXT", nullable: true),
                    KindRaw = table.Column<string>(type: "TEXT", nullable: false, defaultValue: "task"),
                    ResumeNote = table.Column<string>(type: "TEXT", nullable: true),
                    SwitchAwayCount = table.Column<int>(type: "INTEGER", nullable: false, defaultValue: 0),
                    CompletedAt = table.Column<string>(type: "TEXT", nullable: true),
                    ParentId = table.Column<Guid>(type: "TEXT", nullable: true),
                    IsSensitive = table.Column<bool>(type: "INTEGER", nullable: false, defaultValue: false),
                    RecurrenceJson = table.Column<string>(type: "TEXT", nullable: true),
                    ReminderOverrideJson = table.Column<string>(type: "TEXT", nullable: true),
                    DelegationJson = table.Column<string>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Tasks", x => x.Id);
                    table.ForeignKey(
                        name: "FK_Tasks_Tasks_ParentId",
                        column: x => x.ParentId,
                        principalTable: "Tasks",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateTable(
                name: "Conditions",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    TaskId = table.Column<Guid>(type: "TEXT", nullable: false),
                    OrderIndex = table.Column<int>(type: "INTEGER", nullable: false),
                    Kind = table.Column<string>(type: "TEXT", nullable: false),
                    TaskDoneTargetId = table.Column<Guid>(type: "TEXT", nullable: true),
                    AfterDate = table.Column<string>(type: "TEXT", nullable: true),
                    ExternalDescription = table.Column<string>(type: "TEXT", nullable: true),
                    ExternalSatisfied = table.Column<bool>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Conditions", x => x.Id);
                    table.ForeignKey(
                        name: "FK_Conditions_Tasks_TaskId",
                        column: x => x.TaskId,
                        principalTable: "Tasks",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "ReminderRecords",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    TaskId = table.Column<Guid>(type: "TEXT", nullable: false),
                    FireAt = table.Column<string>(type: "TEXT", nullable: false),
                    OffsetKind = table.Column<string>(type: "TEXT", nullable: false),
                    State = table.Column<string>(type: "TEXT", nullable: false, defaultValue: "scheduled"),
                    IsHighUrgency = table.Column<bool>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ReminderRecords", x => x.Id);
                    table.ForeignKey(
                        name: "FK_ReminderRecords_Tasks_TaskId",
                        column: x => x.TaskId,
                        principalTable: "Tasks",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_CompletionEvents_CompletedAt",
                table: "CompletionEvents",
                column: "CompletedAt");

            migrationBuilder.CreateIndex(
                name: "IX_CompletionEvents_ParentIdSnapshot",
                table: "CompletionEvents",
                column: "ParentIdSnapshot");

            migrationBuilder.CreateIndex(
                name: "IX_CompletionEvents_TaskId",
                table: "CompletionEvents",
                column: "TaskId");

            migrationBuilder.CreateIndex(
                name: "IX_Conditions_TaskId_OrderIndex",
                table: "Conditions",
                columns: new[] { "TaskId", "OrderIndex" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_ParseCorrections_CreatedAt",
                table: "ParseCorrections",
                column: "CreatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_ReminderRecords_FireAt",
                table: "ReminderRecords",
                column: "FireAt");

            migrationBuilder.CreateIndex(
                name: "IX_ReminderRecords_TaskId",
                table: "ReminderRecords",
                column: "TaskId");

            migrationBuilder.CreateIndex(
                name: "IX_Tasks_CreatedAt",
                table: "Tasks",
                column: "CreatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_Tasks_ParentId",
                table: "Tasks",
                column: "ParentId");

            migrationBuilder.CreateIndex(
                name: "IX_Tasks_StatusRaw",
                table: "Tasks",
                column: "StatusRaw");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "CompletionEvents");

            migrationBuilder.DropTable(
                name: "Conditions");

            migrationBuilder.DropTable(
                name: "ParseCorrections");

            migrationBuilder.DropTable(
                name: "ReminderRecords");

            migrationBuilder.DropTable(
                name: "Tasks");
        }
    }
}
