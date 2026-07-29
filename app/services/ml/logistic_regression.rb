# frozen_string_literal: true

module Ml
  # Pure-Ruby binary logistic regression, fitted by iteratively reweighted
  # least squares (Newton-Raphson) — issue #302 step 3. No gem: the model is
  # ~7 coefficients on a few hundred thousand rows, which IRLS solves
  # deterministically in a handful of iterations; a native-extension ML stack
  # would be a heavyweight dependency for one weighted sum.
  #
  # A small L2 ridge (never on the intercept) keeps coefficients finite on
  # separable data and conditions the Hessian; at the default 1e-4 its shrink
  # on real, noisy financial labels is negligible.
  #
  # Deterministic by construction: zero initialization, fixed iteration order,
  # no randomness — the same dataset always yields the same coefficients,
  # which is what lets a frozen artifact be re-derived and audited.
  class LogisticRegression
    DEFAULT_L2 = 1e-4
    MAX_ETA = 30.0 # exp overflow guard; sigmoid saturates far earlier anyway

    attr_reader :intercept, :weights, :iterations, :converged

    def initialize(intercept:, weights:, iterations: 0, converged: true)
      @intercept = intercept.to_f
      @weights = weights.map(&:to_f)
      @iterations = iterations
      @converged = converged
    end

    # rows: array of feature arrays (all the same length); targets: 0/1.
    def self.fit(rows, targets, l2: DEFAULT_L2, max_iterations: 50, tolerance: 1e-10)
      raise ArgumentError, "empty dataset" if rows.empty?
      raise ArgumentError, "rows/targets size mismatch" unless rows.size == targets.size

      dims = rows.first.size
      raise ArgumentError, "ragged feature rows" unless rows.all? { |r| r.size == dims }

      beta = Array.new(dims + 1, 0.0) # [intercept, w1..wp]
      iterations = 0
      converged = false

      max_iterations.times do
        iterations += 1
        gradient, hessian = newton_terms(rows, targets, beta, dims)

        # Ridge on the weights only — penalizing the intercept would bias the
        # fitted base rate, which the calibration report depends on.
        (1..dims).each do |j|
          gradient[j] -= l2 * beta[j]
          hessian[j][j] += l2
        end

        delta = solve_linear_system(hessian, gradient)
        (0..dims).each { |j| beta[j] += delta[j] }

        if delta.map(&:abs).max < tolerance
          converged = true
          break
        end
      end

      new(intercept: beta[0], weights: beta[1..], iterations: iterations, converged: converged)
    end

    def predict_probability(row)
      eta = @intercept
      @weights.each_with_index { |w, j| eta += w * row[j] }
      1.0 / (1.0 + Math.exp(-eta.clamp(-MAX_ETA, MAX_ETA)))
    end

    class << self
      private

      # One Newton step's ingredients: gradient of the log-likelihood and the
      # (negated) Hessian X'WX, both over the design matrix with an implicit
      # leading 1 for the intercept.
      def newton_terms(rows, targets, beta, dims)
        gradient = Array.new(dims + 1, 0.0)
        hessian = Array.new(dims + 1) { Array.new(dims + 1, 0.0) }

        rows.each_index do |i|
          x = rows[i]
          eta = beta[0]
          x.each_with_index { |v, j| eta += beta[j + 1] * v }
          mu = 1.0 / (1.0 + Math.exp(-eta.clamp(-MAX_ETA, MAX_ETA)))
          w = [mu * (1.0 - mu), 1e-10].max
          residual = targets[i] - mu

          gradient[0] += residual
          hessian[0][0] += w
          x.each_with_index do |xj, j|
            gradient[j + 1] += residual * xj
            wxj = w * xj
            hessian[0][j + 1] += wxj
            hessian[j + 1][0] += wxj
            x.each_with_index do |xk, k|
              hessian[j + 1][k + 1] += wxj * xk
            end
          end
        end

        [gradient, hessian]
      end

      # Gaussian elimination with partial pivoting. The system is (p+1) square
      # for our ~7 features — exactness and determinism matter, speed does not.
      def solve_linear_system(matrix, vector)
        n = vector.size
        a = matrix.map(&:dup)
        b = vector.dup

        (0...n).each do |col|
          pivot = (col...n).max_by { |r| a[r][col].abs }
          raise ArgumentError, "singular system (degenerate features)" if a[pivot][col].abs < 1e-300

          a[col], a[pivot] = a[pivot], a[col]
          b[col], b[pivot] = b[pivot], b[col]

          ((col + 1)...n).each do |r|
            factor = a[r][col] / a[col][col]
            next if factor.zero?

            (col...n).each { |c| a[r][c] -= factor * a[col][c] }
            b[r] -= factor * b[col]
          end
        end

        solution = Array.new(n, 0.0)
        (n - 1).downto(0) do |r|
          sum = b[r]
          ((r + 1)...n).each { |c| sum -= a[r][c] * solution[c] }
          solution[r] = sum / a[r][r]
        end
        solution
      end
    end
  end
end
