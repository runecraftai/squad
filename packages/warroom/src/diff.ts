export type DiffLineType = "unchanged" | "added" | "removed";
export interface DiffLine {
	type: DiffLineType;
	text: string;
}

/** Line-based LCS diff. Structural only: it never claims to parse a Git patch or prove ancestry. */
export function lineDiff(a: string, b: string): DiffLine[] {
	const linesA = a === "" ? [] : a.split("\n");
	const linesB = b === "" ? [] : b.split("\n");
	const n = linesA.length;
	const m = linesB.length;
	const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
	for (let i = n - 1; i >= 0; i--) {
		for (let j = m - 1; j >= 0; j--) {
			lcs[i][j] = linesA[i] === linesB[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
		}
	}
	const result: DiffLine[] = [];
	let i = 0;
	let j = 0;
	while (i < n && j < m) {
		if (linesA[i] === linesB[j]) {
			result.push({ type: "unchanged", text: linesA[i] });
			i++;
			j++;
		} else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
			result.push({ type: "removed", text: linesA[i] });
			i++;
		} else {
			result.push({ type: "added", text: linesB[j] });
			j++;
		}
	}
	while (i < n) {
		result.push({ type: "removed", text: linesA[i] });
		i++;
	}
	while (j < m) {
		result.push({ type: "added", text: linesB[j] });
		j++;
	}
	return result;
}
