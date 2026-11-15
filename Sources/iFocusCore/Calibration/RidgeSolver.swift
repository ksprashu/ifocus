import Foundation

public enum RidgeSolver {
    /// Solves `(Phi^T Phi + lambda * N * D) w = Phi^T y` with `D = diag(0, 1, ..., 1)`
    /// via Cholesky factorisation.
    public static func solve(
        designMatrix phi: [[Double]],
        targets y: [Double],
        lambda: Double = 0.05
    ) -> [Double]? {
        guard let solved = solveMulti(designMatrix: phi, targetColumns: [y], lambda: lambda) else {
            return nil
        }
        return solved.first
    }

    public static func solveMulti(
        designMatrix phi: [[Double]],
        targetColumns: [[Double]],
        lambda: Double = 0.05
    ) -> [[Double]]? {
        let n = phi.count
        guard n > 0, let p = phi.first?.count, p > 0 else { return nil }
        guard lambda.isFinite, lambda >= 0 else { return nil }
        for col in targetColumns where col.count != n { return nil }

        var a = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        var rhs = Array(repeating: Array(repeating: 0.0, count: p), count: targetColumns.count)

        for rowIdx in 0..<n {
            let row = phi[rowIdx]
            guard row.count == p else { return nil }
            for i in 0..<p {
                let ri = row[i]
                guard ri.isFinite else { return nil }
                for c in 0..<targetColumns.count {
                    let yi = targetColumns[c][rowIdx]
                    guard yi.isFinite else { return nil }
                    rhs[c][i] += ri * yi
                }
                for j in i..<p {
                    a[i][j] += ri * row[j]
                }
            }
        }

        for i in 0..<p {
            for j in 0..<i {
                a[i][j] = a[j][i]
            }
        }

        let reg = lambda * Double(n)
        for j in 1..<p {
            a[j][j] += reg
        }

        var l = Array(repeating: Array(repeating: 0.0, count: p), count: p)
        for i in 0..<p {
            for j in 0...i {
                var sum = a[i][j]
                for k in 0..<j {
                    sum -= l[i][k] * l[j][k]
                }
                if i == j {
                    guard sum.isFinite, sum > 1e-12 else { return nil }
                    l[i][j] = sqrt(sum)
                } else {
                    let diag = l[j][j]
                    guard diag > 1e-12 else { return nil }
                    l[i][j] = sum / diag
                }
            }
        }

        var solutions: [[Double]] = []
        solutions.reserveCapacity(targetColumns.count)

        for c in 0..<targetColumns.count {
            let b = rhs[c]
            var z = Array(repeating: 0.0, count: p)
            for i in 0..<p {
                var sum = b[i]
                for k in 0..<i {
                    sum -= l[i][k] * z[k]
                }
                z[i] = sum / l[i][i]
            }

            var w = Array(repeating: 0.0, count: p)
            for i in stride(from: p - 1, through: 0, by: -1) {
                var sum = z[i]
                for k in (i + 1)..<p {
                    sum -= l[k][i] * w[k]
                }
                let val = sum / l[i][i]
                guard val.isFinite else { return nil }
                w[i] = val
            }
            solutions.append(w)
        }

        return solutions
    }
}
