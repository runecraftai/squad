export type DiffLineType = "unchanged" | "added" | "removed";
export interface DiffLine {
	type: DiffLineType;
	text: string;
}

/** Above this many table cells, diffLines switches from a single quadratic-memory pass to Hirschberg's linear-space divide-and-conquer, so peak memory stays bounded by this constant regardless of input size. */
const QUADRATIC_CELL_BUDGET = 4_000_000;

/** Line-based LCS diff. Structural only: it never claims to parse a Git patch or prove ancestry. */
export function lineDiff(a: string, b: string): DiffLine[] {
	const linesA = a === "" ? [] : a.split("\n");
	const linesB = b === "" ? [] : b.split("\n");
	return diffLines(linesA, linesB);
}

function diffLines(a: string[], b: string[]): DiffLine[] {
	const n = a.length;
	const m = b.length;
	if (n === 0) return b.map((text): DiffLine => ({ type: "added", text }));
	if (m === 0) return a.map((text): DiffLine => ({ type: "removed", text }));
	if ((n + 1) * (m + 1) <= QUADRATIC_CELL_BUDGET) return quadraticDiff(a, b);
	if (n === 1) return diffSingleLine(a[0], b);

	// Hirschberg's algorithm: split `a` at its midpoint, find the column of `b` an optimal LCS
	// must pass through there (forward and reversed-backward LCS-length scans, each O(m) space),
	// then recurse on both halves. Peak memory stays O(n+m) instead of O(n*m), at every input size.
	const mid = n >> 1;
	const forward = lcsLengthRow(a.slice(0, mid), b);
	const backward = lcsLengthRow([...a.slice(mid)].reverse(), [...b].reverse());
	let splitAt = 0;
	let best = -1;
	for (let k = 0; k <= m; k++) {
		const score = forward[k] + backward[m - k];
		if (score > best) {
			best = score;
			splitAt = k;
		}
	}
	return [...diffLines(a.slice(0, mid), b.slice(0, splitAt)), ...diffLines(a.slice(mid), b.slice(splitAt))];
}

/** The last row of the LCS-length DP table for `a` vs `b`: O(a.length * b.length) time, O(b.length) space. */
function lcsLengthRow(a: string[], b: string[]): number[] {
	let previous = new Array<number>(b.length + 1).fill(0);
	for (let i = 0; i < a.length; i++) {
		const current = new Array<number>(b.length + 1).fill(0);
		for (let j = 0; j < b.length; j++) {
			current[j + 1] = a[i] === b[j] ? previous[j] + 1 : Math.max(previous[j + 1], current[j]);
		}
		previous = current;
	}
	return previous;
}

/** A single line against many: O(m) time/space, no 2D table. Only reached when a quadratic pass over `b` alone would still exceed the budget. */
function diffSingleLine(line: string, b: string[]): DiffLine[] {
	const index = b.indexOf(line);
	if (index === -1) return [{ type: "removed", text: line }, ...b.map((text): DiffLine => ({ type: "added", text }))];
	return [
		...b.slice(0, index).map((text): DiffLine => ({ type: "added", text })),
		{ type: "unchanged", text: line },
		...b.slice(index + 1).map((text): DiffLine => ({ type: "added", text })),
	];
}

/** Full O(n*m)-memory LCS diff, used directly whenever the table is cheap enough to build outright. */
function quadraticDiff(a: string[], b: string[]): DiffLine[] {
	const n = a.length;
	const m = b.length;
	const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
	for (let i = n - 1; i >= 0; i--) {
		for (let j = m - 1; j >= 0; j--) {
			lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
		}
	}
	const result: DiffLine[] = [];
	let i = 0;
	let j = 0;
	while (i < n && j < m) {
		if (a[i] === b[j]) {
			result.push({ type: "unchanged", text: a[i] });
			i++;
			j++;
		} else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
			result.push({ type: "removed", text: a[i] });
			i++;
		} else {
			result.push({ type: "added", text: b[j] });
			j++;
		}
	}
	while (i < n) {
		result.push({ type: "removed", text: a[i] });
		i++;
	}
	while (j < m) {
		result.push({ type: "added", text: b[j] });
		j++;
	}
	return result;
}
