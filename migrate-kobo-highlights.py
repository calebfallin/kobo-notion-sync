#!/usr/bin/env python3
"""Convert a Kobo database snapshot + unchanged KEPUB to Readest annotations.

Read-only inputs. Refuses to export a highlight whose selected book text differs.
Uses only Python's standard library. No credentials or network requests.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import posixpath
import re
import sqlite3
import unicodedata
from urllib.parse import unquote
from xml.dom import Node, minidom
import zipfile


def elements(node):
    return [child for child in node.childNodes if child.nodeType == Node.ELEMENT_NODE]


def text_nodes(node):
    for child in node.childNodes:
        if child.nodeType in (Node.TEXT_NODE, Node.CDATA_SECTION_NODE):
            yield child
        else:
            yield from text_nodes(child)


def units(text):
    return len(text.encode('utf-16-le')) // 2


def normalize(text):
    return ' '.join(unicodedata.normalize('NFC', text).split())


def path_to(node):
    """CFI steps below the document element, without optional ID assertions."""
    if node.parentNode.nodeType == Node.DOCUMENT_NODE:
        return []
    siblings = node.parentNode.childNodes
    if node.nodeType == Node.ELEMENT_NODE:
        step = (elements(node.parentNode).index(node) + 1) * 2
    else:
        prior_elements = 0
        for sibling in siblings:
            if sibling is node:
                break
            if sibling.nodeType == Node.ELEMENT_NODE:
                prior_elements += 1
        step = prior_elements * 2 + 1
    return path_to(node.parentNode) + [str(step)]


def endpoint(doc, selector, offset):
    match = re.fullmatch(r'span#(.+)', selector or '')
    if not match:
        raise ValueError('Unsupported Kobo container selector')
    element_id = match.group(1).replace('\\', '')
    matches = [node for node in doc.getElementsByTagName('*')
               if node.getAttribute('id') == element_id]
    if len(matches) != 1:
        raise ValueError('Kobo highlight anchor is missing or ambiguous')
    if offset is None or offset < 0:
        raise ValueError('Invalid text offset')
    for node in text_nodes(matches[0]):
        length = units(node.data)
        if offset <= length:
            # Reject positions between the two halves of a Unicode surrogate pair.
            node.data.encode('utf-16-le')[:offset * 2].decode('utf-16-le')
            return node, offset
        offset -= length
    raise ValueError('Kobo text offset exceeds the container text')


def make_range(doc, start, end, spine_path):
    nodes = list(text_nodes(doc.documentElement))
    left = sum(units(n.data) for n in nodes[:nodes.index(start[0])]) + start[1]
    right = sum(units(n.data) for n in nodes[:nodes.index(end[0])]) + end[1]
    if right <= left:
        raise ValueError('Highlight range is empty or reversed')
    selected = ''.join(n.data for n in nodes).encode('utf-16-le')[left * 2:right * 2].decode('utf-16-le')
    a, b = path_to(start[0]), path_to(end[0])
    shared = 0
    # Keep the text-node step in each endpoint, even for a single-node range.
    while shared < min(len(a), len(b)) - 1 and a[shared] == b[shared]:
        shared += 1
    common = '/' + '/'.join(a[:shared]) if shared else ''
    first = '/' + '/'.join(a[shared:]) + ':' + str(start[1])
    last = '/' + '/'.join(b[shared:]) + ':' + str(end[1])
    return f'epubcfi({spine_path}!{common},{first},{last})', selected


def timestamp(value):
    if not value:
        return 0
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp() * 1000)


def convert(database, book, volume_id):
    db = sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    try:
        title = db.execute('SELECT Title, Attribution FROM content WHERE ContentID = ? AND ContentType = 6', (volume_id,)).fetchall()
        if len(title) != 1:
            raise ValueError('Expected exactly one matching Kobo book')
        highlights = db.execute("SELECT * FROM Bookmark WHERE VolumeID = ? AND LOWER(CAST(COALESCE(Hidden, 0) AS TEXT)) IN ('0', 'false', '') ORDER BY DateCreated, BookmarkID", (volume_id,)).fetchall()
    finally:
        db.close()
    notes = []
    with zipfile.ZipFile(book) as archive:
        container = minidom.parseString(archive.read('META-INF/container.xml'))
        opf_path = container.getElementsByTagName('rootfile')[0].getAttribute('full-path')
        opf = minidom.parseString(archive.read(opf_path))
        manifest = {item.getAttribute('id'): posixpath.normpath(posixpath.join(posixpath.dirname(opf_path), unquote(item.getAttribute('href'))))
                    for item in opf.getElementsByTagName('item')}
        spine = opf.getElementsByTagName('spine')[0]
        sections = {manifest[item.getAttribute('idref')]: '/' + '/'.join(path_to(item))
                    for item in elements(spine)}
        documents = {}
        for item in highlights:
            if not item['Text']:
                continue  # Dog-ear bookmarks are outside this highlight migration.
            if item['Type'] != 'highlight':
                raise ValueError('Unexpected annotation type; migration stopped')
            try:
                # Kobo KEPUB IDs encode the archive path after the first !.
                chapter = unquote(item['ContentID'].split('!', 1)[1].split('#', 1)[0].replace('!', '/'))
                if chapter not in documents:
                    documents[chapter] = minidom.parseString(archive.read(chapter))
                doc = documents[chapter]
                start = endpoint(doc, item['StartContainerPath'], item['StartOffset'])
                end = endpoint(doc, item['EndContainerPath'], item['EndOffset'])
                cfi, selected = make_range(doc, start, end, sections[chapter])
                if normalize(selected) != normalize(item['Text']):
                    raise ValueError('Selected text differs from the saved highlight')
                created = timestamp(item['DateCreated'])
                notes.append({'id': item['BookmarkID'], 'type': 'annotation', 'cfi': cfi,
                              'text': item['Text'], 'note': item['Annotation'] or '',
                              'style': 'highlight', 'color': 'yellow',
                              'createdAt': created, 'updatedAt': max(created, timestamp(item['DateModified']))})
            except (ValueError, KeyError, IndexError, UnicodeError) as error:
                raise ValueError(f'Highlight {item["BookmarkID"]}: {error}') from error
    if not notes:
        raise ValueError('No text highlights found; no export created')
    return {'$format': 'readest-annotations', 'version': 1,
            'exportedAt': int(datetime.now(timezone.utc).timestamp() * 1000),
            'book': {'title': title[0]['Title'], 'author': title[0]['Attribution'], 'format': 'EPUB'},
            'annotations': notes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True, type=Path, help='KoboReader.sqlite snapshot')
    parser.add_argument('--book', required=True, type=Path, help='Exact, unchanged Kobo KEPUB file')
    parser.add_argument('--volume-id', required=True, help='Exact content.ContentID of this book')
    parser.add_argument('--output', required=True, type=Path, help='New private Readest JSON file')
    args = parser.parse_args()
    payload = convert(args.database, args.book, args.volume_id)
    # Exclusive creation prevents accidental replacement of a previous export.
    import os
    with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as output:
        json.dump(payload, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(f'Validated and exported {len(payload["annotations"])} highlights. Inputs unchanged.')


if __name__ == '__main__':
    main()
