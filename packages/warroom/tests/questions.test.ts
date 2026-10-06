import { describe, expect, test } from "bun:test";
import { Warroom } from "../src/core.ts";

function seeded() {
	const warroom = new Warroom();
	warroom.command({ type: "initiative.create", id: "i1", title: "Proof" });
	warroom.command({ type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan one" });
	return warroom;
}

describe("question and answer controls", () => {
	test("a question binds to one exact revision and starts open", () => {
		const w = seeded();
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Safe fallback?", context: "storage choice" });
		const question = w.state("i1").questions[0];
		expect(question.id).toBe("q1");
		expect(question.revisionId).toBe("p1");
		expect(question.status).toBe("open");
		w.close();
	});

	test("answering binds the answer to the question's revision and closes it", () => {
		const w = seeded();
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Safe fallback?" });
		w.command({ type: "question.answer", id: "ans1", initiativeId: "i1", questionId: "q1", answer: "Use source-of-truth A" });
		const question = w.state("i1").questions.find((item) => item.id === "q1");
		expect(question.status).toBe("answered");
		expect(question.answer).toBe("Use source-of-truth A");
		expect(question.revisionId).toBe("p1");
		w.close();
	});

	test("answering twice is rejected because the question is no longer open", () => {
		const w = seeded();
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Safe fallback?" });
		w.command({ type: "question.answer", id: "ans1", initiativeId: "i1", questionId: "q1", answer: "First answer" });
		expect(() => w.command({ type: "question.answer", initiativeId: "i1", questionId: "q1", answer: "Second answer" })).toThrow("not open");
		w.close();
	});

	test("answering a question that does not exist is rejected", () => {
		const w = seeded();
		expect(() => w.command({ type: "question.answer", initiativeId: "i1", questionId: "missing", answer: "..." })).toThrow("does not exist");
		w.close();
	});

	test("a newer plan revision marks the question outdated and mechanically blocks answering", () => {
		const w = seeded();
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Safe fallback?" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		const question = w.state("i1").questions.find((item) => item.id === "q1");
		expect(question.status).toBe("outdated");
		expect(() => w.command({ type: "question.answer", initiativeId: "i1", questionId: "q1", answer: "Too late" })).toThrow("not open");
		w.close();
	});

	test("an answered question is retained as outdated, not deleted, when the revision changes", () => {
		const w = seeded();
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Safe fallback?" });
		w.command({ type: "question.answer", id: "ans1", initiativeId: "i1", questionId: "q1", answer: "Answer A" });
		w.command({ type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "plan two" });
		const state = w.state("i1");
		expect(state.questions).toHaveLength(1);
		const question = state.questions.find((item) => item.id === "q1");
		expect(question.status).toBe("outdated");
		expect(question.answer).toBe("Answer A");
		const persisted = w.db.query("SELECT status, answer FROM questions WHERE id='q1'").get() as { status: string; answer: string };
		expect(persisted.status).toBe("outdated");
		expect(persisted.answer).toBe("Answer A");
		w.close();
	});

	test("a question can bind to a code revision as well as a plan revision", () => {
		const w = seeded();
		w.command({ type: "revision.create", id: "c1", initiativeId: "i1", kind: "code", content: "code one" });
		w.command({ type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "c1", prompt: "Why this approach?" });
		expect(w.state("i1").questions[0].revisionId).toBe("c1");
		w.close();
	});
});
