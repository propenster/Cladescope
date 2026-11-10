#include "tree.h"

#include <QFile>
#include <QFileInfo>
#include <QMetaObject>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSet>
#include <QTextStream>
#include <QThread>
#include <functional>

namespace {

typedef std::function<void(const QString &, double)> Report;

bool isDelimiter(QChar c)
{
    return c == '(' || c == ')' || c == ',' || c == ':' || c == ';' || c == '[';
}

// ============================================================ Newick / Nexus

// Support value stored in a BEAST / MrBayes style annotation, e.g.
//   [&height=1.2,height_95%_HPD={0.9,1.5},posterior=0.98]   or   [&prob=0.99,prob_stddev=0.01]
// `body` is the text after the "&". Returns the value as written (e.g. "0.98"), or an empty
// string if the annotation carries no recognised support key. Commas inside {...} or "..."
// do not split entries.
QString annotationSupport(const QString &body)
{
    static const QStringList keys = {"posterior", "prob", "probability", "pp", "support",
                                     "bootstrap", "bs", "prob(percent)"};
    QHash<QString, QString> found;
    QString cur;
    int brace = 0;
    bool quoted = false;
    auto flush = [&]() {
        const int eq = cur.indexOf('=');
        if (eq > 0) {
            QString k = cur.left(eq).trimmed().toLower();
            QString v = cur.mid(eq + 1).trimmed();
            if (k.size() >= 2 && k.startsWith('"') && k.endsWith('"')) k = k.mid(1, k.size() - 2);
            if (v.size() >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.mid(1, v.size() - 2);
            if (!found.contains(k)) found.insert(k, v.trimmed());
        }
        cur.clear();
    };
    for (const QChar c : body) {
        if (c == '"') quoted = !quoted;
        else if (!quoted && c == '{') ++brace;
        else if (!quoted && c == '}') brace = qMax(0, brace - 1);
        if (c == ',' && !quoted && brace == 0) { flush(); continue; }
        cur += c;
    }
    flush();
    for (const QString &k : keys) {
        auto it = found.constFind(k);
        if (it == found.constEnd()) continue;
        bool ok = false;
        it->toDouble(&ok);
        if (ok) return *it;
    }
    return QString();
}

// Iterative Newick parser. Handles quoted labels, [comments], scientific
// notation branch lengths and internal node labels (e.g. support values),
// including BEAST/MrBayes [&posterior=...] annotations on internal nodes.
ParsedTree parseNewick(const QString &text, const std::function<void(double)> &progress)
{
    ParsedTree t;
    QVector<char> hasKid;   // node has at least one child (so a comment after it annotates an internal node)
    auto addNode = [&t, &hasKid](int parent) -> int {
        t.names.append(QString());
        t.lengths.append(0.0);
        t.parents.append(parent);
        hasKid.append(0);
        if (parent >= 0) hasKid[parent] = 1;
        return t.names.size() - 1;
    };

    int cur = addNode(-1);
    QVector<int> stack;
    const int n = text.size();
    const int reportStep = qMax(1, n / 25);
    int nextReport = reportStep;
    int i = 0;

    while (i < n) {
        if (i >= nextReport) {
            nextReport += reportStep;
            if (progress) progress(double(i) / double(n));
        }
        const QChar c = text.at(i);

        if (c.isSpace()) { ++i; continue; }

        if (c == '[') { // comment, may be nested
            const int cs = i;
            int depth = 0;
            while (i < n) {
                const QChar d = text.at(i++);
                if (d == '[') ++depth;
                else if (d == ']' && --depth == 0) break;
            }
            // A BEAST/MrBayes annotation on an internal node, e.g. ")[&posterior=0.98]:0.5",
            // becomes that node's support value unless the node already has a label.
            if (cs + 1 < n && text.at(cs + 1) == '&' && cur != 0 && hasKid[cur] && t.names[cur].isEmpty()
                && i - cs >= 3 && text.at(i - 1) == ']') {
                const QString v = annotationSupport(text.mid(cs + 2, i - cs - 3));
                if (!v.isEmpty()) t.names[cur] = v;
            }
            continue;
        }
        if (c == ';') break;

        if (c == '(') {
            const int node = addNode(cur);
            stack.append(cur);
            cur = node;
            ++i;
            continue;
        }
        if (c == ')') {
            if (stack.isEmpty()) {
                t.error = "Unbalanced parentheses: unexpected ')'.";
                return t;
            }
            cur = stack.takeLast();
            ++i;
            continue;
        }
        if (c == ',') {
            if (t.parents[cur] < 0) {
                t.error = "Malformed Newick: comma outside parentheses.";
                return t;
            }
            const int node = addNode(t.parents[cur]);
            cur = node;
            ++i;
            continue;
        }
        if (c == ':') {
            ++i;
            while (i < n && text.at(i).isSpace()) ++i;
            const int s = i;
            while (i < n && (text.at(i).isDigit() || text.at(i) == '.' || text.at(i) == '-'
                             || text.at(i) == '+' || text.at(i) == 'e' || text.at(i) == 'E'))
                ++i;
            t.lengths[cur] = text.mid(s, i - s).toDouble();
            continue;
        }

        QString label;
        if (c == '\'') {
            ++i;
            while (i < n) {
                if (text.at(i) == '\'') {
                    if (i + 1 < n && text.at(i + 1) == '\'') { label += '\''; i += 2; continue; }
                    ++i;
                    break;
                }
                label += text.at(i++);
            }
        } else {
            const int s = i;
            while (i < n && !isDelimiter(text.at(i))) ++i;
            label = text.mid(s, i - s).trimmed();
        }
        t.names[cur] = label;
    }

    if (!stack.isEmpty())
        t.error = "Unbalanced parentheses: missing ')'.";
    return t;
}

QString extractNexusTree(const QString &content, QHash<QString, QString> &translate)
{
    QRegularExpression trRe("\\btranslate\\b(.*?);",
                            QRegularExpression::CaseInsensitiveOption
                                | QRegularExpression::DotMatchesEverythingOption);
    const QRegularExpressionMatch tm = trRe.match(content);
    if (tm.hasMatch()) {
        const QStringList entries = tm.captured(1).split(',', Qt::SkipEmptyParts);
        for (const QString &entry : entries) {
            const QString e = entry.trimmed();
            const int sp = e.indexOf(QRegularExpression("\\s"));
            if (sp <= 0) continue;
            QString key = e.left(sp);
            QString val = e.mid(sp).trimmed();
            if (val.size() >= 2 && val.startsWith('\'') && val.endsWith('\''))
                val = val.mid(1, val.size() - 2);
            translate.insert(key, val);
        }
    }

    QRegularExpression treeRe("\\btree\\s+\\*?\\s*(?:'[^']*'|[^\\s=]+)\\s*=",
                              QRegularExpression::CaseInsensitiveOption);
    const QRegularExpressionMatch m = treeRe.match(content);
    if (!m.hasMatch()) return QString();
    const int start = m.capturedEnd();
    const int end = content.indexOf(';', start);
    return content.mid(start, end < 0 ? -1 : end - start).trimmed();
}

ParsedTree loadAndParse(const QString &path, const QString &inlineText, const Report &report)
{
    ParsedTree fail;
    QString content = inlineText;

    if (!path.isEmpty()) {
        report("Reading file", 0.05);
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            fail.error = "Could not open file: " + path;
            return fail;
        }
        QTextStream in(&file);
        content = in.readAll();
    }

    content = content.trimmed();
    if (content.isEmpty()) {
        fail.error = "The file is empty.";
        return fail;
    }

    report("Detecting format", 0.18);
    QHash<QString, QString> translate;
    if (content.startsWith("#NEXUS", Qt::CaseInsensitive)) {
        report("Reading Nexus block", 0.22);
        content = extractNexusTree(content, translate);
        if (content.isEmpty()) {
            fail.error = "No tree found in the Nexus file.";
            return fail;
        }
    }

    ParsedTree t = parseNewick(content, [&report](double f) { report("Parsing branches", 0.25 + 0.55 * f); });
    if (!t.error.isEmpty()) return t;
    if (t.names.size() < 2) {
        t.error = "The file does not contain a valid tree.";
        return t;
    }

    report("Resolving taxa", 0.82);
    QVector<char> hasChild(t.names.size(), 0);
    for (int i = 1; i < t.names.size(); ++i) hasChild[t.parents[i]] = 1;
    int tips = 0;
    for (int i = 0; i < t.names.size(); ++i) {
        if (hasChild[i]) continue;
        ++tips;
        if (!translate.isEmpty()) {
            auto it = translate.constFind(t.names[i]);
            if (it != translate.constEnd()) t.names[i] = it.value();
        }
    }
    t.tipCount = tips;
    report("Indexing nodes", 0.88);
    return t;
}

QString quoteLabel(const QString &s)
{
    if (s.isEmpty()) return s;
    static const QString special = " ()[]:;,'";
    for (QChar c : s) {
        if (special.contains(c)) {
            QString q = s;
            q.replace("'", "''");
            return "'" + q + "'";
        }
    }
    return s;
}

// Iterative Newick writer for the subtree rooted at `start`.
QString treeToNewick(const ParsedTree &t, int start)
{
    const int n = t.names.size();
    QVector<QVector<int>> children(n);
    for (int i = 1; i < n; ++i) children[t.parents[i]].append(i);

    struct Frame { int node; int next; };
    QVector<Frame> st;
    st.append(Frame{start, 0});
    QString out;

    while (!st.isEmpty()) {
        const int fi = st.size() - 1;
        const int node = st[fi].node;
        const QVector<int> &ch = children[node];
        if (st[fi].next == 0 && !ch.isEmpty()) out += QLatin1Char('(');
        if (st[fi].next < ch.size()) {
            if (st[fi].next > 0) out += QLatin1Char(',');
            const int child = ch[st[fi].next++];
            st.append(Frame{child, 0});
        } else {
            if (!ch.isEmpty()) out += QLatin1Char(')');
            out += quoteLabel(t.names[node]);
            if (node != start && t.lengths[node] > 0) {
                out += QLatin1Char(':');
                out += QString::number(t.lengths[node], 'g', 12);
            }
            st.removeLast();
        }
    }
    out += QLatin1Char(';');
    return out;
}

// ---- demo tree (clade-correlated "regions" so pattern colouring looks good)
QString demoClade(QRandomGenerator &rng, int tips, int region, int &counter)
{
    static const QStringList regions = {"Kenya", "Brazil", "India", "USA", "China", "UK", "Peru"};
    auto len = [&rng]() { return QString::number(0.01 + rng.generateDouble() * 0.09, 'f', 4); };
    if (tips == 1) {
        return QString("Sample%1_%2_%3:%4")
        .arg(++counter)
            .arg(regions[region])
            .arg(2015 + int(rng.bounded(9)))
            .arg(len());
    }
    const int left = 1 + int(rng.bounded(tips - 1));
    const int rr = rng.bounded(100) < 12 ? int(rng.bounded(regions.size())) : region;
    return "(" + demoClade(rng, left, region, counter) + "," + demoClade(rng, tips - left, rr, counter)
           + ")" + QString::number(60 + int(rng.bounded(40))) + ":" + len();
}

// ============================================================ editing helpers

struct Adj { int to; double len; QString lab; };
typedef QVector<QVector<Adj>> AdjList;

Adj removeEdge(AdjList &adj, int x, int y, bool *found = nullptr)
{
    Adj res{-1, 0.0, QString()};
    bool ok = false;
    for (int k = 0; k < adj[x].size(); ++k) {
        if (adj[x][k].to == y) { res = adj[x][k]; adj[x].remove(k); ok = true; break; }
    }
    for (int k = 0; k < adj[y].size(); ++k) {
        if (adj[y][k].to == x) { adj[y].remove(k); break; }
    }
    if (found) *found = ok;
    return res;
}

// Undirected view of the tree. Support values / internal labels travel with
// the *branch*, not the node, so they stay correct after rerooting. A
// bifurcating root is suppressed (its two branches are merged).
struct Unrooted {
    AdjList adj;
    int count = 0;
    bool rootSuppressed = false;
    int a = -1, b = -1;
};

Unrooted buildUnrooted(const ParsedTree &t)
{
    Unrooted u;
    const int n = t.names.size();
    u.count = n;
    u.adj.resize(n + 1); // spare slot for the new root
    QVector<char> hasChild(n, 0);
    for (int i = 1; i < n; ++i) hasChild[t.parents[i]] = 1;
    for (int i = 1; i < n; ++i) {
        const int p = t.parents[i];
        const QString lab = hasChild[i] ? t.names[i] : QString();
        u.adj[i].append(Adj{p, t.lengths[i], lab});
        u.adj[p].append(Adj{i, t.lengths[i], lab});
    }
    if (u.adj[0].size() == 2) {
        const Adj ea = u.adj[0][0], eb = u.adj[0][1];
        removeEdge(u.adj, ea.to, 0);
        removeEdge(u.adj, eb.to, 0);
        u.adj[0].clear();
        const QString lab = !ea.lab.isEmpty() ? ea.lab : eb.lab;
        const double len = ea.len + eb.len;
        u.adj[ea.to].append(Adj{eb.to, len, lab});
        u.adj[eb.to].append(Adj{ea.to, len, lab});
        u.rootSuppressed = true;
        u.a = ea.to;
        u.b = eb.to;
    }
    return u;
}

// Put a new root on the branch a--b, `frac` of the way from a to b.
ParsedTree rerootEdge(const ParsedTree &t, int a, int b, double frac)
{
    ParsedTree out;
    const int n = t.names.size();
    Unrooted u = buildUnrooted(t);

    if (u.rootSuppressed && b == 0 && (a == u.a || a == u.b))
        b = (a == u.a) ? u.b : u.a;

    bool found = false;
    const Adj e = removeEdge(u.adj, a, b, &found);
    if (!found) { out.error = "Cannot reroot on this branch."; return out; }

    const int r = n;
    const double la = e.len * qBound(0.0, frac, 1.0);
    const double lb = e.len - la;
    u.adj[r].append(Adj{a, la, e.lab});
    u.adj[r].append(Adj{b, lb, e.lab});
    u.adj[a].append(Adj{r, la, e.lab});
    u.adj[b].append(Adj{r, lb, e.lab});

    QVector<char> hasChild(n, 0);
    for (int i = 1; i < n; ++i) hasChild[t.parents[i]] = 1;

    struct Fr { int node; int from; int pnew; double len; QString lab; };
    QVector<Fr> st;
    st.append(Fr{r, -1, -1, 0.0, QString()});
    while (!st.isEmpty()) {
        const Fr f = st.takeLast();
        const int idx = out.names.size();
        const bool isTip = f.node < n && !hasChild[f.node];
        out.names.append(isTip ? t.names[f.node] : f.lab);
        out.lengths.append(f.len);
        out.parents.append(f.pnew);
        const QVector<Adj> &nb = u.adj[f.node];
        for (int k = nb.size() - 1; k >= 0; --k) {
            if (nb[k].to == f.from) continue;
            st.append(Fr{nb[k].to, f.node, idx, nb[k].len, nb[k].lab});
        }
    }
    out.tipCount = t.tipCount;
    return out;
}

ParsedTree midpointRoot(const ParsedTree &t)
{
    ParsedTree fail;
    const int n = t.names.size();
    Unrooted u = buildUnrooted(t);

    bool hasLen = false;
    for (double l : t.lengths) if (l > 0) { hasLen = true; break; }
    QVector<char> hasChild(n, 0);
    for (int i = 1; i < n; ++i) hasChild[t.parents[i]] = 1;

    QVector<double> dist(n);
    QVector<int> prev(n);
    auto farthest = [&](int s) -> int {
        dist.fill(-1.0);
        prev.fill(-1);
        QVector<int> st;
        st.append(s);
        dist[s] = 0.0;
        while (!st.isEmpty()) {
            const int x = st.takeLast();
            const QVector<Adj> &nb = u.adj[x];
            for (const Adj &e : nb) {
                if (dist[e.to] >= 0.0) continue;
                dist[e.to] = dist[x] + (hasLen ? e.len : 1.0);
                prev[e.to] = x;
                st.append(e.to);
            }
        }
        int best = s;
        double bd = -1.0;
        for (int i = 0; i < n; ++i)
            if (!hasChild[i] && dist[i] > bd) { bd = dist[i]; best = i; }
        return best;
    };

    int s = -1;
    for (int i = 1; i < n; ++i) if (!hasChild[i]) { s = i; break; }
    if (s < 0) { fail.error = "Tree has no tips."; return fail; }

    const int A = farthest(s);
    const int B = farthest(A);   // dist[] / prev[] are now rooted at A
    const double half = dist[B] / 2.0;

    QVector<int> path;
    for (int x = B; x != -1; x = prev[x]) path.prepend(x);
    if (path.size() < 2) { fail.error = "Tree is too small to root."; return fail; }

    for (int k = 0; k + 1 < path.size(); ++k) {
        const double d0 = dist[path[k]], d1 = dist[path[k + 1]];
        if (half <= d1 || k + 2 == path.size()) {
            const double frac = d1 > d0 ? (half - d0) / (d1 - d0) : 0.5;
            return rerootEdge(t, path[k], path[k + 1], frac);
        }
    }
    fail.error = "Could not locate the midpoint.";
    return fail;
}

ParsedTree extractSubtree(const ParsedTree &t, int node)
{
    ParsedTree out;
    const int n = t.names.size();
    QVector<int> size(n, 1);
    for (int i = n - 1; i > 0; --i) size[t.parents[i]] += size[i];
    const int end = node + size[node];
    QVector<char> hasChild(end - node, 0);
    for (int i = node; i < end; ++i) {
        out.names.append(t.names[i]);
        out.lengths.append(i == node ? 0.0 : t.lengths[i]);
        out.parents.append(i == node ? -1 : t.parents[i] - node);
        if (i > node) hasChild[t.parents[i] - node] = 1;
    }
    out.names[0].clear(); // a support value on the clade root is meaningless now
    for (int i = 0; i < hasChild.size(); ++i) if (!hasChild[i]) ++out.tipCount;
    return out;
}

// ================================================================= metadata

QStringList splitDelimited(const QString &line, QChar delim)
{
    QStringList out;
    QString cur;
    bool quoted = false;
    for (int i = 0; i < line.size(); ++i) {
        const QChar c = line.at(i);
        if (quoted) {
            if (c == '"') {
                if (i + 1 < line.size() && line.at(i + 1) == '"') { cur += '"'; ++i; }
                else quoted = false;
            } else cur += c;
        } else if (c == '"' && cur.trimmed().isEmpty()) {
            cur.clear();
            quoted = true;
        } else if (c == delim) {
            out.append(cur.trimmed());
            cur.clear();
        } else cur += c;
    }
    out.append(cur.trimmed());
    return out;
}

} // namespace

// -----------------------------------------------------------------------------

TreeModel::TreeModel(QObject *parent) : QObject(parent) {}

TreeModel::~TreeModel()
{
    if (m_thread) m_thread->wait();
}

QString TreeModel::localPath(const QUrl &url) const
{
    return url.isLocalFile() ? url.toLocalFile() : url.toString();
}

void TreeModel::loadFile(const QUrl &fileUrl)
{
    startJob(fileUrl.fileName(), localPath(fileUrl), QString());
}

void TreeModel::loadPath(const QString &path)
{
    startJob(QFileInfo(path).fileName(), path, QString());
}

void TreeModel::loadExample()
{
    QRandomGenerator rng(20260101);
    int counter = 0;
    const QString nwk = demoClade(rng, 64, 0, counter) + ";";
    startJob("example.nwk", QString(), nwk);
}

void TreeModel::startJob(const QString &displayName, const QString &path, const QString &inlineText)
{
    if (m_loading) return;
    m_loading = true;
    emit loadingChanged();
    emit loadStarted(displayName);

    QThread *thread = QThread::create([this, displayName, path, inlineText]() {
        Report report = [this](const QString &stage, double f) {
            QMetaObject::invokeMethod(this, [this, stage, f]() { emit progress(stage, f); },
                                      Qt::QueuedConnection);
        };
        ParsedTree result = loadAndParse(path, inlineText, report);
        QMetaObject::invokeMethod(this, [this, displayName, result]() { finishLoad(displayName, result); },
                                  Qt::QueuedConnection);
    });
    m_thread = thread;
    connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    thread->start();
}

void TreeModel::finishLoad(const QString &displayName, const ParsedTree &tree)
{
    m_loading = false;
    emit loadingChanged();

    if (!tree.isValid()) {
        emit errorOccurred(tree.error.isEmpty() ? QStringLiteral("The file does not contain a valid tree.")
                                                : tree.error);
        return;
    }

    m_undo.clear();
    m_metaRows.clear();
    m_metaColumns.clear();
    m_metaKey.clear();
    m_metaTotal = 0;

    emit progress("Preparing view", 0.9);
    commitTree(tree, displayName, QString());
}

void TreeModel::rebuildTreeData()
{
    QVariantList parents, lengths;
    parents.reserve(m_tree.parents.size());
    lengths.reserve(m_tree.lengths.size());
    for (int p : m_tree.parents) parents.append(p);
    for (double l : m_tree.lengths) lengths.append(l);

    QVariantMap map;
    map["count"] = m_tree.names.size();
    map["names"] = m_tree.names;
    map["parents"] = parents;
    map["lengths"] = lengths;
    m_treeData = map;
}

void TreeModel::commitTree(const ParsedTree &tree, const QString &fileName, const QString &message)
{
    m_tree = tree;
    if (!fileName.isEmpty()) m_fileName = fileName;
    rebuildTreeData();
    publishMetadata();
    emit treeLoaded();      // canvas rebuilds first ...
    emit metadataChanged(); // ... then receives metadata aligned to the new tree
    emit undoChanged();
    if (!message.isEmpty()) emit edited(message);
}

// ================================================================== metadata

void TreeModel::publishMetadata()
{
    QVariantMap map;
    const int n = m_tree.names.size();
    const int nc = m_metaColumns.size();
    if (nc == 0 || n < 2) {
        map["columns"] = QStringList();
        map["values"] = QVariantList();
        map["matched"] = 0;
        map["rows"] = 0;
        map["key"] = QString();
        m_metadata = map;
        return;
    }

    QVector<char> hasChild(n, 0);
    for (int i = 1; i < n; ++i) hasChild[m_tree.parents[i]] = 1;

    QVector<QStringList> cols(nc);
    for (int c = 0; c < nc; ++c) cols[c].fill(QString(), n);

    int matched = 0;
    for (int i = 0; i < n; ++i) {
        if (hasChild[i]) continue;
        auto it = m_metaRows.constFind(m_tree.names[i]);
        if (it == m_metaRows.constEnd()) continue;
        ++matched;
        for (int c = 0; c < nc && c < it->size(); ++c) cols[c][i] = it->at(c);
    }

    QVariantList values;
    for (int c = 0; c < nc; ++c) values.append(QVariant(cols[c]));
    map["columns"] = m_metaColumns;
    map["values"] = values;
    map["matched"] = matched;
    map["rows"] = m_metaTotal;
    map["key"] = m_metaKey;
    m_metadata = map;
}

void TreeModel::loadMetadata(const QUrl &fileUrl)
{
    const int n = m_tree.names.size();
    if (n < 2) { emit errorOccurred("Load a tree before importing metadata."); return; }

    QFile file(localPath(fileUrl));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        emit errorOccurred("Could not open file: " + file.fileName());
        return;
    }
    QTextStream in(&file);
    QStringList lines = in.readAll().split(QRegularExpression("\r\n|\n|\r"), Qt::SkipEmptyParts);
    file.close();
    if (lines.size() < 2) { emit errorOccurred("The metadata file needs a header row and at least one data row."); return; }
    if (lines[0].startsWith(QChar(0xFEFF))) lines[0].remove(0, 1);

    // delimiter: whichever of tab / comma / semicolon is most frequent in the header
    const int tabs = lines[0].count('\t'), commas = lines[0].count(','), semis = lines[0].count(';');
    QChar delim = '\t';
    if (commas > tabs && commas >= semis) delim = ',';
    else if (semis > tabs && semis > commas) delim = ';';

    const QStringList header = splitDelimited(lines[0], delim);
    const int ncol = header.size();
    if (ncol < 2) { emit errorOccurred("Could not find at least two columns (tab, comma or semicolon separated)."); return; }

    QVector<QStringList> rows;
    rows.reserve(lines.size() - 1);
    for (int i = 1; i < lines.size(); ++i) {
        if (lines[i].startsWith('#')) continue;
        QStringList f = splitDelimited(lines[i], delim);
        while (f.size() < ncol) f.append(QString());
        rows.append(f);
    }

    // tip names of the current tree
    QVector<char> hasChild(n, 0);
    for (int i = 1; i < n; ++i) hasChild[m_tree.parents[i]] = 1;
    QSet<QString> tipNames;
    for (int i = 0; i < n; ++i) if (!hasChild[i]) tipNames.insert(m_tree.names[i]);

    // the key column is the one whose values match the most tip names
    int bestCol = 0, bestHits = -1;
    for (int c = 0; c < ncol; ++c) {
        int hits = 0;
        for (const QStringList &r : rows) if (tipNames.contains(r[c])) ++hits;
        if (hits > bestHits) { bestHits = hits; bestCol = c; }
    }
    if (bestHits <= 0) {
        emit errorOccurred("None of the metadata columns match the tip names in this tree.\n"
                           "Make sure one column contains the exact tip labels.");
        return;
    }

    m_metaColumns.clear();
    for (int c = 0; c < ncol; ++c) if (c != bestCol) m_metaColumns.append(header[c]);
    m_metaKey = header[bestCol];
    m_metaTotal = rows.size();
    m_metaRows.clear();
    for (const QStringList &r : rows) {
        QStringList vals;
        for (int c = 0; c < ncol; ++c) if (c != bestCol) vals.append(r[c]);
        m_metaRows.insert(r[bestCol], vals);
    }

    publishMetadata();
    emit metadataChanged();
    emit metadataLoaded(m_metadata.value("matched").toInt(), m_metaTotal, m_metaKey);
}

void TreeModel::clearMetadata()
{
    m_metaColumns.clear();
    m_metaRows.clear();
    m_metaKey.clear();
    m_metaTotal = 0;
    publishMetadata();
    emit metadataChanged();
}

// ================================================================ tree edits

void TreeModel::applyEdit(const ParsedTree &tree, const QString &message, const QString &fileName)
{
    if (!tree.isValid()) {
        emit errorOccurred(tree.error.isEmpty() ? QStringLiteral("That edit could not be applied.") : tree.error);
        return;
    }
    m_undo.append(m_tree);
    if (m_undo.size() > 10) m_undo.removeFirst();
    commitTree(tree, fileName, message);
}

void TreeModel::rerootAt(int node)
{
    if (node <= 0 || node >= m_tree.names.size()) return;
    applyEdit(rerootEdge(m_tree, node, m_tree.parents[node], 0.5), "Rerooted on selected branch");
}

void TreeModel::midpointRoot()
{
    if (m_tree.tipCount < 3) { emit errorOccurred("Midpoint rooting needs at least 3 tips."); return; }
    applyEdit(::midpointRoot(m_tree), "Midpoint rooted");
}

void TreeModel::extractClade(int node)
{
    const int n = m_tree.names.size();
    if (node <= 0 || node >= n) return;
    ParsedTree sub = extractSubtree(m_tree, node);
    if (sub.tipCount < 2) { emit errorOccurred("Select a clade with at least two tips."); return; }
    QString name = m_fileName;
    if (!name.endsWith(" (clade)")) name += " (clade)";
    applyEdit(sub, QString("Extracted clade · %1 tips").arg(sub.tipCount), name);
}

QString TreeModel::subtreeNewick(int node) const
{
    if (node < 0 || node >= m_tree.names.size()) return QString();
    return treeToNewick(m_tree, node);
}

void TreeModel::undo()
{
    if (m_undo.isEmpty()) return;
    const ParsedTree prev = m_undo.takeLast();
    commitTree(prev, QString(), "Undid last edit");
}

bool TreeModel::saveNewick(const QUrl &fileUrl)
{
    if (m_tree.names.size() < 2) return false;
    QFile file(localPath(fileUrl));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        emit errorOccurred("Could not write file: " + file.fileName());
        return false;
    }
    QTextStream out(&file);
    out << treeToNewick(m_tree, 0) << "\n";
    return true;
}
