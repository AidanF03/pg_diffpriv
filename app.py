import psycopg2
import psycopg2.extras
from flask import Flask, render_template_string, request, redirect, url_for, flash
from markupsafe import Markup

app = Flask(__name__)
app.secret_key = "diffpriv_ui_secret"

DB = dict(host="localhost", dbname="postgres", user="postgres", password="postgres", port=5432)

def get_conn():
    return psycopg2.connect(**DB)

BASE = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>pg_diffpriv UI</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; background: #f5f5f0; color: #1a1a1a; font-size: 15px; }
  nav { background: #1a1a1a; color: #fff; padding: 0 2rem; padding-right: 14rem; display: flex; justify-content: center; gap: 2rem; align-items: center; height: 52px; }
  nav a { color: #ccc; text-decoration: none; font-size: 14px; }
  nav a:hover, nav a.active { color: #fff; }
  nav .brand { color: #DC143C; font-weight: 600; font-size: 15px; margin-right: 1rem; }
  main { max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 20px; font-weight: 600; margin-bottom: 1.5rem; }
  h2 { font-size: 16px; font-weight: 600; margin-bottom: 1rem; }
  .card { background: #fff; border: 0.5px solid #ddd; border-radius: 10px; padding: 1.25rem; margin-bottom: 1.5rem; }
  label { display: block; font-size: 13px; color: #555; margin-bottom: 4px; margin-top: 12px; }
  input, select { width: 100%; padding: 8px 10px; border: 1px solid #ccc; border-radius: 6px; font-size: 14px; background: #fff; }
  input:focus, select:focus { outline: 2px solid #4a90d9; border-color: transparent; }
  button { margin-top: 1rem; padding: 9px 20px; background: #1a1a1a; color: #fff; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; }
  button:hover { background: #333; }
  .flash { padding: 10px 14px; border-radius: 6px; margin-bottom: 1rem; font-size: 14px; }
  .flash.success { background: #e6f4ea; color: #1e6e3a; border: 1px solid #a8d5b5; }
  .flash.error { background: #fdecea; color: #8b1a1a; border: 1px solid #f5b8b8; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 8px 10px; border-bottom: 1.5px solid #ddd; color: #555; font-weight: 500; }
  td { padding: 8px 10px; border-bottom: 0.5px solid #eee; }
  tr:last-child td { border-bottom: none; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 500; }
  .badge.ok { background: #e6f4ea; color: #1e6e3a; }
  .badge.warn { background: #fff3e0; color: #8a5200; }
  .badge.danger { background: #fdecea; color: #8b1a1a; }
  .badge.rejected { background: #f3f3f3; color: #666; }
  .progress-bar { background: #eee; border-radius: 4px; height: 8px; overflow: hidden; }
  .progress-fill { height: 100%; border-radius: 4px; transition: width 0.3s; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
  .result-box { background: #f0f7ff; border: 1px solid #b3d4f5; border-radius: 8px; padding: 1rem; margin-top: 1rem; }
  .result-box .val { font-size: 28px; font-weight: 600; color: #1a5fa8; }
  .result-box .meta { font-size: 12px; color: #555; margin-top: 4px; }
  .delta-row { display: none; }
  small { color: #888; font-size: 12px; }
</style>
<script>
function toggleDelta() {
  var m = document.getElementById('mechanism').value;
  var rows = document.querySelectorAll('.delta-row');
  rows.forEach(function(r) { r.style.display = m === 'gaussian' ? 'block' : 'none'; });
}
function toggleSumAvg() {
  var q = document.getElementById('query_type').value;
  var extra = document.getElementById('extra-fields');
  extra.style.display = (q === 'sum' || q === 'avg') ? 'block' : 'none';
}
</script>
</head>
<body>
<nav>
  <span class="brand">pg_diffpriv</span>
  <a href="/" class="{{ 'active' if active == 'home' }}">Dashboard</a>
  <a href="/analysts" class="{{ 'active' if active == 'analysts' }}">Analysts</a>
  <a href="/query" class="{{ 'active' if active == 'query' }}">Run Query</a>
  <a href="/history" class="{{ 'active' if active == 'history' }}">Query History</a>
</nav>
<main>
{% with messages = get_flashed_messages(with_categories=true) %}
  {% for cat, msg in messages %}
    <div class="flash {{ cat }}">{{ msg }}</div>
  {% endfor %}
{% endwith %}
{{ content }}
</main>
</body>
</html>
"""

def render(content, active=""):
    return render_template_string(BASE, content=Markup(content), active=active)


@app.route("/")
def dashboard():
    try:
        conn = get_conn()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM diffpriv.budget_status ORDER BY analyst_id")
        analysts = cur.fetchall()
        cur.execute("SELECT COUNT(*) as total FROM diffpriv.query_log WHERE approved = TRUE")
        approved = cur.fetchone()["total"]
        cur.execute("SELECT COUNT(*) as total FROM diffpriv.query_log WHERE approved = FALSE")
        rejected = cur.fetchone()["total"]
        cur.execute("SELECT COUNT(*) as total FROM diffpriv.analysts WHERE is_active = TRUE")
        active_count = cur.fetchone()["total"]
        cur.close(); conn.close()
    except Exception as e:
        return render(f"<p style='color:red'>DB error: {e}</p>", "home")

    rows = ""
    for a in analysts:
        pct = float(a["pct_used"] or 0)
        if pct >= 100:
            color = "#e24b4a"; badge = "danger"; label = "exhausted"
        elif pct >= 90:
            color = "#ef9f27"; badge = "warn"; label = "90%+ used"
        elif pct >= 75:
            color = "#ef9f27"; badge = "warn"; label = "75%+ used"
        else:
            color = "#1d9e75"; badge = "ok"; label = "healthy"

        rows += f"""
        <tr>
          <td>{a['analyst_id']}</td>
          <td><strong>{a['analyst_name']}</strong></td>
          <td>{float(a['total_budget']):.4f}</td>
          <td>{float(a['budget_used']):.4f}</td>
          <td>{float(a['budget_remaining']):.4f}</td>
          <td>
            <div style="display:flex; align-items:center; gap:8px;">
              <div class="progress-bar" style="width:100px">
                <div class="progress-fill" style="width:{min(pct,100):.1f}%; background:{color}"></div>
              </div>
              <span style="font-size:12px">{pct:.1f}%</span>
            </div>
          </td>
          <td><span class="badge {badge}">{label}</span></td>
          <td>{a['approved_queries']} / {a['rejected_queries']}</td>
        </tr>"""

    content = f"""
    <h1>Dashboard</h1>
    <div class="grid2" style="grid-template-columns: repeat(3, 1fr); margin-bottom: 1.5rem;">
      <div class="card" style="text-align:center; padding: 1rem;">
        <div style="font-size:12px; color:#888; margin-bottom:4px">Active analysts</div>
        <div style="font-size:28px; font-weight:600">{active_count}</div>
      </div>
      <div class="card" style="text-align:center; padding: 1rem;">
        <div style="font-size:12px; color:#888; margin-bottom:4px">Approved queries</div>
        <div style="font-size:28px; font-weight:600; color:#1d9e75">{approved}</div>
      </div>
      <div class="card" style="text-align:center; padding: 1rem;">
        <div style="font-size:12px; color:#888; margin-bottom:4px">Rejected queries</div>
        <div style="font-size:28px; font-weight:600; color:#e24b4a">{rejected}</div>
      </div>
    </div>
    <div class="card">
      <h2>Budget status</h2>
      <table>
        <tr>
          <th>ID</th><th>Name</th><th>Total &epsilon;</th><th>Used</th><th>Remaining</th>
          <th>Usage</th><th>Status</th><th>Approved / Rejected</th>
        </tr>
        {rows if rows else '<tr><td colspan="8" style="text-align:center; color:#999; padding:1.5rem">No analysts registered yet.</td></tr>'}
      </table>
    </div>
    """
    return render(content, "home")


@app.route("/analysts", methods=["GET", "POST"])
def analysts():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        budget = request.form.get("budget", "").strip()
        if not name or not budget:
            flash("Name and budget are required.", "error")
            return redirect(url_for("analysts"))
        try:
            budget = float(budget)
            if budget <= 0:
                raise ValueError
        except ValueError:
            flash("Budget must be a positive number.", "error")
            return redirect(url_for("analysts"))
        try:
            conn = get_conn()
            cur = conn.cursor()
            cur.execute("SELECT diffpriv.register_analyst(%s, %s)", (name, budget))
            conn.commit(); cur.close(); conn.close()
            flash(f"Analyst '{name}' registered with budget {budget}.", "success")
        except Exception as e:
            flash(f"Error: {e}", "error")
        return redirect(url_for("analysts"))

    try:
        conn = get_conn()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM diffpriv.analysts ORDER BY analyst_id")
        rows_data = cur.fetchall()
        cur.close(); conn.close()
    except Exception as e:
        return render(f"<p style='color:red'>DB error: {e}</p>", "analysts")

    rows = ""
    for a in rows_data:
        status = "Active" if a["is_active"] else "Inactive"
        rows += f"""
        <tr>
          <td>{a['analyst_id']}</td>
          <td>{a['analyst_name']}</td>
          <td>{float(a['total_budget']):.4f}</td>
          <td>{float(a['budget_used']):.4f}</td>
          <td>{float(a['total_budget'] - a['budget_used']):.4f}</td>
          <td>{status}</td>
        </tr>"""

    content = f"""
    <h1>Analysts</h1>
    <div class="card">
      <h2>Register new analyst</h2>
      <form method="POST">
        <div class="grid2">
          <div>
            <label>Analyst name</label>
            <input type="text" name="name" placeholder="e.g. alice" required>
          </div>
          <div>
            <label>Total epsilon budget</label>
            <input type="number" name="budget" step="0.001" min="0.001" placeholder="e.g. 1.0" required>
          </div>
        </div>
        <button type="submit">Register analyst</button>
      </form>
    </div>
    <div class="card">
      <h2>All analysts</h2>
      <table>
        <tr><th>ID</th><th>Name</th><th>Total &epsilon;</th><th>Used</th><th>Remaining</th><th>Status</th></tr>
        {rows if rows else '<tr><td colspan="6" style="text-align:center; color:#999; padding:1.5rem">No analysts yet.</td></tr>'}
      </table>
    </div>
    """
    return render(content, "analysts")


@app.route("/query", methods=["GET", "POST"])
def query():
    result_html = ""
    if request.method == "POST":
        try:
            analyst_id = int(request.form["analyst_id"])
            table = request.form["table"].strip()
            where = request.form.get("where", "").strip() or None
            pk_col = request.form.get("pk_col", "").strip()
            k = int(request.form.get("k", 1) or 1)
            epsilon = float(request.form["epsilon"])
            mechanism = request.form["mechanism"]
            query_type = request.form["query_type"]
            column = request.form.get("column", "").strip() or None
            col_max = request.form.get("col_max", "").strip()
            delta = float(request.form.get("delta", 0) or 0)

            conn = get_conn()
            cur = conn.cursor()

            if query_type == "count":
                if mechanism == "laplace":
                    cur.execute(
                        f"SELECT dp_laplacian_count(%s, t.{pk_col}, %s, %s) FROM {table} t" +
                        (f" WHERE {where}" if where else ""),
                        (analyst_id, epsilon, k)
                    )
                else:
                    cur.execute(
                        f"SELECT dp_gaussian_count(%s, t.{pk_col}, %s, %s, %s) FROM {table} t" +
                        (f" WHERE {where}" if where else ""),
                        (analyst_id, epsilon, k, delta)
                    )
            elif query_type in ("sum", "avg"):
                if not column or not col_max:
                    flash("Column and max are required for sum/avg.", "error")
                    return redirect(url_for("query"))
                col_max = float(col_max)
                if query_type == "sum":
                    fn = "dp_laplacian_sum" if mechanism == "laplace" else "dp_gaussian_sum"
                    if mechanism == "laplace":
                        cur.execute(
                            f"SELECT {fn}(%s, t.{pk_col}, t.{column}, %s, %s, %s) FROM {table} t" +
                            (f" WHERE {where}" if where else ""),
                            (analyst_id, epsilon, k, col_max)
                        )
                    else:
                        cur.execute(
                            f"SELECT {fn}(%s, t.{pk_col}, t.{column}, %s, %s, %s, %s) FROM {table} t" +
                            (f" WHERE {where}" if where else ""),
                            (analyst_id, epsilon, k, col_max, delta)
                        )
                else:
                    fn = "dp_laplacian_avg" if mechanism == "laplace" else "dp_gaussian_avg"
                    if mechanism == "laplace":
                        cur.execute(
                            f"SELECT {fn}(%s, t.{pk_col}, t.{column}, %s, %s, %s) FROM {table} t" +
                            (f" WHERE {where}" if where else ""),
                            (analyst_id, epsilon, k, col_max)
                        )
                    else:
                        cur.execute(
                            f"SELECT {fn}(%s, t.{pk_col}, t.{column}, %s, %s, %s, %s) FROM {table} t" +
                            (f" WHERE {where}" if where else ""),
                            (analyst_id, epsilon, k, col_max, delta)
                        )

            val = cur.fetchone()[0]
            cur.execute("SELECT analyst_name FROM diffpriv.analysts WHERE analyst_id = %s", (analyst_id,))
            name_row = cur.fetchone()
            analyst_name = name_row[0] if name_row else str(analyst_id)
            conn.commit(); cur.close(); conn.close()

            result_html = f"""
            <div class="result-box">
              <div style="font-size:12px; color:#555; margin-bottom:4px">Noisy {query_type.upper()} result</div>
              <div class="val">{float(val):.4f}</div>
              <div class="meta">
                Table: {table} &nbsp;|&nbsp;
                Mechanism: {mechanism} &nbsp;|&nbsp;
                &epsilon; spent: {epsilon}
                {f'| Filter: {where}' if where else ''}
              </div>
            </div>
            """
            flash(f"Query approved. Epsilon {epsilon} deducted from {analyst_name}.", "success")

        except Exception as e:
            err = str(e)
            if "Budget exceeded" in err:
                import re
                requested = re.search(r"Requested=([\d.]+)", err)
                remaining = re.search(r"Remaining=([\d.]+)", err)
                req_val = requested.group(1) if requested else "?"
                rem_val = remaining.group(1) if remaining else "0"
                try:
                    _analyst_id = int(request.form.get("analyst_id", 0))
                    _epsilon = float(request.form.get("epsilon", 0) or 0)
                    _mechanism = request.form.get("mechanism", "")
                    _query_type = request.form.get("query_type", "")
                    _table = request.form.get("table", "").strip()
                    rconn = get_conn()
                    rcur = rconn.cursor()
                    q_text = f"dp_{_mechanism}_{_query_type} on {_table}"
                    notes = f"Budget exceeded: requested={req_val}, remaining={rem_val}"
                    rcur.execute(
                        """INSERT INTO diffpriv.query_log (analyst_id, query_text, epsilon_spent, mechanism, sensitivity, budget_before, budget_after, approved, notes)
                           SELECT %s, %s, %s, %s, 1.0, budget_used, budget_used, FALSE, %s FROM diffpriv.analysts WHERE analyst_id = %s""",
                        (_analyst_id, q_text, _epsilon, _mechanism, notes, _analyst_id)
                    )
                    rconn.commit(); rcur.close(); rconn.close()
                except Exception:
                    pass
                flash(f"Query rejected: budget exhausted. Requested ε={req_val}, remaining ε={rem_val}. No epsilon was deducted.", "error")
            else:
                flash(f"Query failed: {err.split('CONTEXT')[0].strip()}", "error")

    try:
        conn = get_conn()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT analyst_id, analyst_name, total_budget - budget_used as remaining FROM diffpriv.analysts WHERE is_active = TRUE ORDER BY analyst_id")
        analyst_opts = cur.fetchall()
        cur.close(); conn.close()
    except Exception as e:
        analyst_opts = []

    opts = "".join(f'<option value="{a["analyst_id"]}">{a["analyst_name"]} (remaining: {float(a["remaining"]):.4f})</option>' for a in analyst_opts)

    content = f"""
    <h1>Run DP query</h1>
    <div class="card">
      <form method="POST">
        <div class="grid2">
          <div>
            <label>Analyst</label>
            <select name="analyst_id" required>{opts if opts else '<option value="">No analysts registered</option>'}</select>
          </div>
          <div>
            <label>Query type</label>
            <select name="query_type" id="query_type" onchange="toggleSumAvg()">
              <option value="count">COUNT</option>
              <option value="sum">SUM</option>
              <option value="avg">AVG</option>
            </select>
          </div>
        </div>
        <div class="grid2">
          <div>
            <label>Table <small>(schema.table or just table)</small></label>
            <input type="text" name="table" placeholder="e.g. employees" required>
          </div>
          <div>
            <label>WHERE clause <small>(optional)</small></label>
            <input type="text" name="where" placeholder="e.g. is_active = TRUE">
          </div>
        </div>
        <div class="grid2">
          <div>
            <label>Primary key column</label>
            <input type="text" name="pk_col" placeholder="e.g. employee_id" required>
          </div>
          <div>
            <label>Max rows per user (k)</label>
            <input type="number" name="k" min="1" value="1" required>
          </div>
        </div>
        <div id="extra-fields" style="display:none">
          <div class="grid2">
            <div>
              <label>Column name</label>
              <input type="text" name="column" placeholder="e.g. salary">
            </div>
            <div>
              <label>Max column value (e.g. 200000 for salary)</label>
              <input type="number" name="col_max" step="any" placeholder="e.g. 200000">
            </div>
          </div>
        </div>
        <div class="grid2">
          <div>
            <label>Epsilon (&epsilon;)</label>
            <input type="number" name="epsilon" step="0.001" min="0.001" placeholder="e.g. 0.1" required>
          </div>
          <div>
            <label>Mechanism</label>
            <select name="mechanism" id="mechanism" onchange="toggleDelta()">
              <option value="laplace">Laplace</option>
              <option value="gaussian">Gaussian</option>
            </select>
          </div>
        </div>
        <div class="delta-row">
          <label>Delta (&delta;) <small>required for Gaussian, e.g. 1e-5</small></label>
          <input type="number" name="delta" step="any" placeholder="e.g. 0.00001">
        </div>
        <button type="submit">Run query</button>
      </form>
      {result_html}
    </div>
    """
    return render(content, "query")


@app.route("/history")
def history():
    try:
        conn = get_conn()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT * FROM diffpriv.query_history LIMIT 100")
        rows_data = cur.fetchall()
        cur.close(); conn.close()
    except Exception as e:
        return render(f"<p style='color:red'>DB error: {e}</p>", "history")

    rows = ""
    for r in rows_data:
        badge = "ok" if r["approved"] else "rejected"
        label = "approved" if r["approved"] else "rejected"
        rows += f"""
        <tr>
          <td>{r['log_id']}</td>
          <td>{r['analyst_name']}</td>
          <td style="max-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap" title="{r['query_text']}">{r['query_text']}</td>
          <td>{r['mechanism']}</td>
          <td>{float(r['epsilon_spent']):.4f}</td>
          <td>{float(r['budget_before']):.4f} &rarr; {float(r['budget_after']):.4f}</td>
          <td><span class="badge {badge}">{label}</span></td>
          <td>{str(r['query_time'])[:19]}</td>
        </tr>"""

    content = f"""
    <h1>Query history</h1>
    <div class="card">
      <table>
        <tr>
          <th>#</th><th>Analyst</th><th>Query</th><th>Mechanism</th>
          <th>&epsilon; spent</th><th>Budget before &rarr; after</th><th>Status</th><th>Time</th>
        </tr>
        {rows if rows else '<tr><td colspan="8" style="text-align:center; color:#999; padding:1.5rem">No queries yet.</td></tr>'}
      </table>
    </div>
    """
    return render(content, "history")


if __name__ == "__main__":
    app.run(debug=True, port=5050)