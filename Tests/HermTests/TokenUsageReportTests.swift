import Foundation
import Testing

@testable import Herm

@MainActor
struct TokenUsageReportTests {
    /// Shape of Hermes' `/api/analytics/usage`, trimmed from a real response.
    @Test func parsesAnalyticsAndAddsBackgroundWorkToTotals() {
        let report = ControlCenterModel.parseTokenUsage(
            [
                "period_days": 30,
                "totals": [
                    "total_input": 1_000, "total_output": 200, "total_cache_read": 3_000, "total_reasoning": 50,
                    "total_estimated_cost": 1.5, "total_actual_cost": 0, "total_sessions": 4, "total_api_calls": 12,
                ],
                "daily": [
                    [
                        "day": "2026-09-25", "input_tokens": 600, "output_tokens": 100, "cache_read_tokens": 2_000,
                        "reasoning_tokens": 20, "estimated_cost": 1.0, "sessions": 3, "api_calls": 8,
                    ],
                    ["day": "not-a-day", "input_tokens": 1],
                ],
                "by_model": [
                    [
                        "model": "gpt-5.6-luna", "input_tokens": 1_300, "output_tokens": 260, "estimated_cost": 0,
                        "sessions": 4, "api_calls": 15,
                        "aux_tasks": [
                            [
                                "task": "compression", "input_tokens": 100, "output_tokens": 10, "estimated_cost": 0,
                                "api_calls": 1,
                            ],
                            [
                                "task": "compression", "input_tokens": 50, "output_tokens": 5, "estimated_cost": 0,
                                "api_calls": 1,
                            ],
                            [
                                "task": "title_generation", "input_tokens": 400, "output_tokens": 1,
                                "estimated_cost": 0, "api_calls": 1,
                            ],
                        ],
                    ]
                ],
                "by_task": [
                    [
                        "task": "compression", "input_tokens": 300, "output_tokens": 60, "estimated_cost": 0.25,
                        "api_calls": 3, "models": ["gpt-5.6-luna"],
                    ]
                ],
                "tools": [["tool": "terminal", "count": 9, "percentage": 75.0]],
                "skills": [
                    "summary": ["total_skill_loads": 5, "distinct_skills_used": 2],
                    "top_skills": [["skill": "swift", "total_count": 4, "percentage": 80.0]],
                ],
            ],
            models: [
                "models": [
                    ["model": "gpt-5.6-luna", "provider": "openai-codex"],
                    ["model": "gpt-5.6-luna", "provider": ""],
                    ["model": "gpt-5.6-luna", "provider": "openai-codex"],
                ]
            ])

        #expect(report.days == 30)
        #expect(report.models.first?.providers == ["openai-codex"])
        #expect(report.daily.count == 1)
        #expect(report.daily.first?.cacheReadTokens == 2_000)
        #expect(report.totalInputTokens == 1_300)
        #expect(report.totalOutputTokens == 260)
        #expect(report.totalCost == 1.75)
        #expect(report.cacheHitRate == 0.75)
        let tasks = report.models.first?.tasks ?? []
        #expect(tasks.map(\.task) == ["title_generation", "compression"])
        #expect(tasks.last?.inputTokens == 150)
        #expect(tasks.last?.apiCalls == 2)
        #expect(report.tools.first?.name == "terminal")
        #expect(report.skills.first?.count == 4)
        #expect(report.skillLoads == 5)
    }
}
