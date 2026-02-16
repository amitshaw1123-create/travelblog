import os
import re
import sqlite3
from datetime import datetime
from functools import wraps

import markupsafe
from flask import (Flask, abort, flash, g, jsonify, redirect, render_template,
                   request, session, url_for)
from werkzeug.utils import secure_filename

app = Flask(__name__)

# Load .env file if present (for local development)
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

app.secret_key = os.environ.get('SECRET_KEY', 'wanderlog-secret-key-change-in-production')

DATABASE = 'travel_blog.db'
UPLOAD_FOLDER = os.path.join('static', 'uploads')
ALLOWED_IMAGE_EXT = {'png', 'jpg', 'jpeg', 'gif', 'webp'}
ALLOWED_VIDEO_EXT = {'mp4', 'webm', 'ogg', 'mov'}

app.config['MAX_CONTENT_LENGTH'] = 200 * 1024 * 1024  # 200 MB

# ─── Admin credentials (change before deploying) ──────────────────────────────
ADMIN_USERNAME = 'admin'
ADMIN_PASSWORD = 'travel2024'


# ─── Database helpers ─────────────────────────────────────────────────────────

def get_db():
    if 'db' not in g:
        g.db = sqlite3.connect(DATABASE)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
    return g.db


@app.teardown_appcontext
def close_db(error):
    db = g.pop('db', None)
    if db is not None:
        db.close()


def init_db():
    db = sqlite3.connect(DATABASE)
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript('''
        CREATE TABLE IF NOT EXISTS posts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT    NOT NULL,
            slug        TEXT    UNIQUE NOT NULL,
            destination TEXT,
            content     TEXT    NOT NULL,
            cover_image TEXT,
            youtube_url TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS post_images (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            post_id       INTEGER NOT NULL,
            file_path     TEXT    NOT NULL,
            display_order INTEGER DEFAULT 0,
            FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS post_videos (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            post_id       INTEGER NOT NULL,
            file_path     TEXT    NOT NULL,
            display_order INTEGER DEFAULT 0,
            FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS comments (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            post_id    INTEGER NOT NULL,
            name       TEXT    NOT NULL,
            email      TEXT,
            comment    TEXT    NOT NULL,
            rating     INTEGER DEFAULT 5 CHECK(rating BETWEEN 1 AND 5),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
        );
    ''')
    db.commit()
    db.close()


# ─── Template filters & context ───────────────────────────────────────────────

@app.template_filter('nl2br')
def nl2br(value):
    return markupsafe.Markup(
        markupsafe.escape(value).replace('\n', markupsafe.Markup('<br>\n'))
    )


@app.template_filter('youtube_embed')
def youtube_embed(url):
    if not url:
        return ''
    patterns = [
        r'youtube\.com/watch\?v=([^&\s]+)',
        r'youtu\.be/([^?\s]+)',
        r'youtube\.com/embed/([^?\s]+)',
    ]
    for pattern in patterns:
        m = re.search(pattern, url)
        if m:
            return f"https://www.youtube.com/embed/{m.group(1)}"
    return url


@app.context_processor
def inject_globals():
    return {'now': datetime.now()}


# ─── Auth helpers ─────────────────────────────────────────────────────────────

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login', next=request.url))
        return f(*args, **kwargs)
    return decorated


# ─── File upload helpers ──────────────────────────────────────────────────────

def allowed_image(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_IMAGE_EXT


def allowed_video(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_VIDEO_EXT


def save_file(file, subfolder):
    filename = secure_filename(file.filename)
    name, ext = os.path.splitext(filename)
    filename = f"{name}_{int(datetime.now().timestamp())}{ext}"
    folder = os.path.join(app.root_path, UPLOAD_FOLDER, subfolder)
    os.makedirs(folder, exist_ok=True)
    file.save(os.path.join(folder, filename))
    return f"uploads/{subfolder}/{filename}"


def slugify(text):
    text = text.lower()
    text = re.sub(r'[^\w\s-]', '', text)
    text = re.sub(r'[\s_-]+', '-', text)
    return re.sub(r'^-+|-+$', '', text)


# ─── Routes ───────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    db = get_db()
    posts = db.execute('''
        SELECT p.*,
               COALESCE(AVG(c.rating), 0) AS avg_rating,
               COUNT(c.id)                AS comment_count
        FROM posts p
        LEFT JOIN comments c ON p.id = c.post_id
        GROUP BY p.id
        ORDER BY p.created_at DESC
    ''').fetchall()
    return render_template('index.html', posts=posts)


@app.route('/post/<slug>')
def post(slug):
    db  = get_db()
    p   = db.execute('SELECT * FROM posts WHERE slug = ?', (slug,)).fetchone()
    if not p:
        abort(404)
    images   = db.execute('SELECT * FROM post_images WHERE post_id = ? ORDER BY display_order', (p['id'],)).fetchall()
    videos   = db.execute('SELECT * FROM post_videos WHERE post_id = ? ORDER BY display_order', (p['id'],)).fetchall()
    comments = db.execute('SELECT * FROM comments WHERE post_id = ? ORDER BY created_at DESC', (p['id'],)).fetchall()
    avg_row  = db.execute('SELECT COALESCE(AVG(rating), 0) AS avg FROM comments WHERE post_id = ?', (p['id'],)).fetchone()
    return render_template('post.html', post=p, images=images, videos=videos,
                           comments=comments, avg_rating=avg_row['avg'])


@app.route('/post/<slug>/comment', methods=['POST'])
def add_comment(slug):
    db = get_db()
    p  = db.execute('SELECT * FROM posts WHERE slug = ?', (slug,)).fetchone()
    if not p:
        abort(404)
    name    = request.form.get('name', '').strip()
    email   = request.form.get('email', '').strip()
    comment = request.form.get('comment', '').strip()
    try:
        rating = max(1, min(5, int(request.form.get('rating', 5))))
    except ValueError:
        rating = 5
    if not name or not comment:
        flash('Name and comment are required.', 'error')
        return redirect(url_for('post', slug=slug) + '#leave-review')
    db.execute(
        'INSERT INTO comments (post_id, name, email, comment, rating) VALUES (?, ?, ?, ?, ?)',
        (p['id'], name, email, comment, rating)
    )
    db.commit()
    flash('Your review has been posted!', 'success')
    return redirect(url_for('post', slug=slug) + '#comments')


# ─── Admin: auth ──────────────────────────────────────────────────────────────

@app.route('/admin/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if (request.form.get('username') == ADMIN_USERNAME and
                request.form.get('password') == ADMIN_PASSWORD):
            session['logged_in'] = True
            flash('Welcome back, wanderer!', 'success')
            return redirect(request.args.get('next') or url_for('index'))
        flash('Invalid credentials.', 'error')
    return render_template('login.html')


@app.route('/admin/logout')
def logout():
    session.pop('logged_in', None)
    flash('Logged out.', 'success')
    return redirect(url_for('index'))


# ─── Admin: posts ─────────────────────────────────────────────────────────────

@app.route('/admin/create', methods=['GET', 'POST'])
@login_required
def create_post():
    if request.method == 'POST':
        title       = request.form.get('title', '').strip()
        destination = request.form.get('destination', '').strip()
        content     = request.form.get('content', '').strip()
        youtube_url = request.form.get('youtube_url', '').strip()

        if not title or not content:
            flash('Title and content are required.', 'error')
            return render_template('create_post.html')

        db   = get_db()
        slug = base = slugify(title) or 'post'
        n    = 1
        while db.execute('SELECT id FROM posts WHERE slug = ?', (slug,)).fetchone():
            slug = f"{base}-{n}"; n += 1

        cover_image = None
        f = request.files.get('cover_image')
        if f and f.filename and allowed_image(f.filename):
            cover_image = save_file(f, 'images')

        db.execute(
            'INSERT INTO posts (title, slug, destination, content, cover_image, youtube_url) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (title, slug, destination, content, cover_image, youtube_url)
        )
        post_id = db.execute('SELECT last_insert_rowid()').fetchone()[0]

        for i, f in enumerate(request.files.getlist('images')):
            if f.filename and allowed_image(f.filename):
                db.execute('INSERT INTO post_images (post_id, file_path, display_order) VALUES (?, ?, ?)',
                           (post_id, save_file(f, 'images'), i))

        for i, f in enumerate(request.files.getlist('videos')):
            if f.filename and allowed_video(f.filename):
                db.execute('INSERT INTO post_videos (post_id, file_path, display_order) VALUES (?, ?, ?)',
                           (post_id, save_file(f, 'videos'), i))

        db.commit()
        flash('Story published!', 'success')
        return redirect(url_for('post', slug=slug))

    return render_template('create_post.html')


@app.route('/admin/edit/<int:post_id>', methods=['GET', 'POST'])
@login_required
def edit_post(post_id):
    db = get_db()
    p  = db.execute('SELECT * FROM posts WHERE id = ?', (post_id,)).fetchone()
    if not p:
        abort(404)

    if request.method == 'POST':
        title       = request.form.get('title', '').strip()
        destination = request.form.get('destination', '').strip()
        content     = request.form.get('content', '').strip()
        youtube_url = request.form.get('youtube_url', '').strip()

        if not title or not content:
            flash('Title and content are required.', 'error')
            return render_template('edit_post.html', post=p,
                                   images=db.execute('SELECT * FROM post_images WHERE post_id=?', (post_id,)).fetchall(),
                                   videos=db.execute('SELECT * FROM post_videos WHERE post_id=?', (post_id,)).fetchall())

        cover_image = p['cover_image']
        f = request.files.get('cover_image')
        if f and f.filename and allowed_image(f.filename):
            cover_image = save_file(f, 'images')

        db.execute(
            'UPDATE posts SET title=?, destination=?, content=?, cover_image=?, '
            'youtube_url=?, updated_at=CURRENT_TIMESTAMP WHERE id=?',
            (title, destination, content, cover_image, youtube_url, post_id)
        )

        existing = db.execute('SELECT COUNT(*) AS c FROM post_images WHERE post_id=?', (post_id,)).fetchone()['c']
        for i, f in enumerate(request.files.getlist('images')):
            if f.filename and allowed_image(f.filename):
                db.execute('INSERT INTO post_images (post_id, file_path, display_order) VALUES (?, ?, ?)',
                           (post_id, save_file(f, 'images'), existing + i))

        existing = db.execute('SELECT COUNT(*) AS c FROM post_videos WHERE post_id=?', (post_id,)).fetchone()['c']
        for i, f in enumerate(request.files.getlist('videos')):
            if f.filename and allowed_video(f.filename):
                db.execute('INSERT INTO post_videos (post_id, file_path, display_order) VALUES (?, ?, ?)',
                           (post_id, save_file(f, 'videos'), existing + i))

        db.commit()
        flash('Post updated!', 'success')
        slug = db.execute('SELECT slug FROM posts WHERE id=?', (post_id,)).fetchone()['slug']
        return redirect(url_for('post', slug=slug))

    images = db.execute('SELECT * FROM post_images WHERE post_id=?', (post_id,)).fetchall()
    videos = db.execute('SELECT * FROM post_videos WHERE post_id=?', (post_id,)).fetchall()
    return render_template('edit_post.html', post=p, images=images, videos=videos)


@app.route('/admin/delete/<int:post_id>', methods=['POST'])
@login_required
def delete_post(post_id):
    db = get_db()
    db.execute('DELETE FROM posts WHERE id = ?', (post_id,))
    db.commit()
    flash('Post deleted.', 'success')
    return redirect(url_for('index'))


@app.route('/admin/delete-image/<int:image_id>', methods=['POST'])
@login_required
def delete_image(image_id):
    db  = get_db()
    row = db.execute('SELECT * FROM post_images WHERE id = ?', (image_id,)).fetchone()
    if not row:
        abort(404)
    post_id = row['post_id']
    db.execute('DELETE FROM post_images WHERE id = ?', (image_id,))
    db.commit()
    try:
        os.remove(os.path.join(app.root_path, 'static', row['file_path']))
    except OSError:
        pass
    flash('Image removed.', 'success')
    return redirect(url_for('edit_post', post_id=post_id))


@app.route('/admin/delete-video/<int:video_id>', methods=['POST'])
@login_required
def delete_video(video_id):
    db  = get_db()
    row = db.execute('SELECT * FROM post_videos WHERE id = ?', (video_id,)).fetchone()
    if not row:
        abort(404)
    post_id = row['post_id']
    db.execute('DELETE FROM post_videos WHERE id = ?', (video_id,))
    db.commit()
    try:
        os.remove(os.path.join(app.root_path, 'static', row['file_path']))
    except OSError:
        pass
    flash('Video removed.', 'success')
    return redirect(url_for('edit_post', post_id=post_id))


@app.route('/admin/delete-comment/<int:comment_id>', methods=['POST'])
@login_required
def delete_comment(comment_id):
    db  = get_db()
    row = db.execute('SELECT * FROM comments WHERE id = ?', (comment_id,)).fetchone()
    if not row:
        abort(404)
    slug = db.execute('SELECT slug FROM posts WHERE id = ?', (row['post_id'],)).fetchone()['slug']
    db.execute('DELETE FROM comments WHERE id = ?', (comment_id,))
    db.commit()
    flash('Comment removed.', 'success')
    return redirect(url_for('post', slug=slug) + '#comments')


# ─── Admin: AI Writer ─────────────────────────────────────────────────────────

@app.route('/admin/ai-draft', methods=['POST'])
@login_required
def ai_draft():
    """Call the Travel Post Writer Agent and return a JSON draft."""
    from agents.writer_agent import generate_post_draft

    destination    = request.form.get('destination', '').strip()
    highlights_raw = request.form.get('highlights', '').strip()
    style          = request.form.get('style', 'adventurous')

    if not destination:
        return jsonify({'error': 'Destination is required.'}), 400

    highlights = [h.strip() for h in highlights_raw.splitlines() if h.strip()]

    try:
        draft = generate_post_draft(destination, highlights, style)
        return jsonify(draft)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 500
    except RuntimeError as exc:
        return jsonify({'error': str(exc)}), 500
    except Exception as exc:
        import traceback
        traceback.print_exc()
        msg = str(exc)
        # Surface billing/auth errors clearly
        if 'credit balance' in msg or 'billing' in msg.lower():
            msg = 'Anthropic API: insufficient credits. Please top up at console.anthropic.com → Plans & Billing.'
        elif 'authentication' in msg.lower() or 'api_key' in msg.lower():
            msg = 'Invalid ANTHROPIC_API_KEY. Check your .env file.'
        return jsonify({'error': msg}), 500


# ─── Entry point ──────────────────────────────────────────────────────────────

if __name__ == '__main__':
    init_db()
    os.makedirs(os.path.join('static', 'uploads', 'images'), exist_ok=True)
    os.makedirs(os.path.join('static', 'uploads', 'videos'), exist_ok=True)
    app.run(debug=True)
