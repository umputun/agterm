import type { Register } from 'claude-code'

const PLACEHOLDER = /\[Image #(\d+)\]/g
// a terminal cell is about twice as tall as it is wide; the Image box stretches to fill
const CELL_ASPECT = 0.5
const MAX_COLUMNS = 80
const MAX_ROWS = 30

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

type Size = { width: number; height: number }

// decodes the first 24 bytes: PNG signature plus the IHDR width and height
const pngSize = (base64: string): Size | null => {
  const head = new Uint8Array(24)
  for (let i = 0; i < 8; i++) {
    const quad = [...base64.slice(i * 4, i * 4 + 4)].reduce((acc, ch) => (acc << 6) | Math.max(0, B64.indexOf(ch)), 0)
    head.set([(quad >> 16) & 0xff, (quad >> 8) & 0xff, quad & 0xff], i * 3)
  }
  const isPng = head.length >= 24 && head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47
  if (!isPng) {
    return null
  }
  const view = new DataView(head.buffer)

  return { width: view.getUint32(16), height: view.getUint32(20) }
}

const boxFor = (size: Size, viewColumns: number, viewRows: number) => {
  let columns = Math.max(1, Math.min(MAX_COLUMNS, viewColumns - 4))
  let rows = Math.round((columns * size.height * CELL_ASPECT) / size.width)
  const maxRows = Math.max(1, Math.min(MAX_ROWS, Math.floor(viewRows / 2)))
  if (rows > maxRows) {
    rows = maxRows
    columns = Math.max(1, Math.round((rows * size.width) / (size.height * CELL_ASPECT)))
  }

  return { columns: Math.min(columns, 255), rows: Math.max(1, Math.min(rows, 255)) }
}

export const register: Register = on => {
  let projectDir: string | undefined
  const sizes = new Map<string, Size | null>()

  // claude code stores pastes in <tmp>/claude-<uid>/<project slug>/<session id>/images/<n>.png;
  // the session id is read per render because /clear switches it without a session.start
  on('session.start', async ($, e, next) => {
    const tmp = (await $.env.get('CLAUDE_CODE_TMPDIR')) ?? '/tmp'
    const { stdout } = await $.process.run(['id', '-u'])
    const base = `${tmp}/claude-${stdout.trim()}`
    if (!(await $.fs.exists(base))) {
      $.ui.log(`pasted-images: ${base} not found, images stay as placeholders`)
      return next(e)
    }
    const real = (await $.fs.stat(base, { resolve: true })).realPath ?? base
    const slug = (await $.session.root()).replace(/[^a-zA-Z0-9]/g, '-')
    projectDir = `${real}/${slug}`

    return next(e)
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const own = await next(e)
    if (e.surface !== 'terminal' || projectDir === undefined || e.props.origin.kind !== 'composer') {
      return own
    }

    const imagesDir = `${projectDir}/${await $.session.id()}/images`
    const ids = [...new Set([...e.props.text.matchAll(PLACEHOLDER)].map(m => m[1] ?? ''))].filter(Boolean)
    const shown: { id: string; path: string; size: Size }[] = []
    for (const id of ids) {
      const path = `${imagesDir}/${id}.png`
      if (!sizes.has(path)) {
        // fs.read rejects files over 4 MiB; one rejection would drop every image in the row
        const bytes = (await $.fs.exists(path)) ? await $.fs.read(path, { as: 'bytes' }).catch(() => null) : null
        sizes.set(path, bytes ? pngSize(bytes.base64) : null)
      }
      const size = sizes.get(path)
      if (size) {
        shown.push({ id, path, size })
      }
    }
    if (shown.length === 0) {
      return own
    }

    const { Box, Image } = $.ui.resolve(e)
    const viewColumns = e.viewport?.columns ?? 100
    const viewRows = e.viewport?.rows ?? 40

    return (
      <Box flexDirection="column">
        {own}
        {shown.map(img => (
          <Box key={`img-${img.id}`} paddingLeft={2}>
            <Image
              key={`image-${img.id}`}
              source={{ file: img.path, format: 'png' }}
              alt={`[Image #${img.id}]`}
              {...boxFor(img.size, viewColumns, viewRows)}
            />
          </Box>
        ))}
      </Box>
    )
  })
}
