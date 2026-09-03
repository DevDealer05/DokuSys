// Supabase Edge Function: ai-agent
// Empfängt Code-Change-Requests aus der iOS App,
// ruft Gemini 2.0 auf und committed via GitHub API

const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? ''
const GITHUB_TOKEN = Deno.env.get('GITHUB_TOKEN') ?? ''
const GITHUB_REPO = 'DevDealer05/DokuSys'

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Content-Type': 'application/json'
}

interface AgentRequest {
  prompt: string
  repoContext?: string
}

interface CodeChange {
  file: string
  action: string
  content: string
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS })
  }

  try {
    const body: AgentRequest = await req.json()
    const { prompt, repoContext } = body

    if (!prompt) {
      return new Response(
        JSON.stringify({ error: 'prompt required' }),
        { status: 400, headers: CORS_HEADERS }
      )
    }

    // Step 1: Get Swift files from GitHub
    const swiftFiles = await getSwiftFiles()

    // Step 2: Call Gemini for analysis + code generation
    const geminiResult = await callGemini(prompt, swiftFiles, repoContext)

    // Step 3: Commit code changes if any
    let commitSHA: string | null = null
    if (geminiResult.codeChanges.length > 0 && GITHUB_TOKEN) {
      commitSHA = await commitToGitHub(geminiResult.codeChanges, prompt)
    }

    return new Response(JSON.stringify({
      text: geminiResult.text,
      codeChanges: geminiResult.codeChanges,
      commitSHA,
      actionsUrl: commitSHA ? `https://github.com/${GITHUB_REPO}/actions` : null
    }), { headers: CORS_HEADERS })

  } catch (err) {
    console.error('Agent error:', err)
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: CORS_HEADERS }
    )
  }
})

// --- GitHub helpers ---

async function getSwiftFiles(): Promise<string[]> {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${GITHUB_REPO}/git/trees/main?recursive=1`,
      { headers: { Authorization: `Bearer ${GITHUB_TOKEN}`, Accept: 'application/vnd.github+json' } }
    )
    const data = await res.json()
    return (data.tree ?? [])
      .filter((f: { path: string; type: string }) => f.path.endsWith('.swift'))
      .map((f: { path: string }) => f.path)
  } catch {
    return []
  }
}

async function callGemini(
  prompt: string,
  files: string[],
  context?: string
): Promise<{ text: string; codeChanges: CodeChange[] }> {
  const systemPrompt = `Du bist ein iOS Swift Entwicklungs-Agent für "Digitales Büro" (SwiftUI iOS 17+, Repo: ${GITHUB_REPO}).
Vorhandene Swift-Dateien: ${files.join(', ')}.

Wenn Code-Änderungen gewünscht werden:
1. Erkläre zuerst klar auf Deutsch, was du änderst.
2. Antworte ZWINGEND am Ende mit einem JSON-Array im Format:
CODE_CHANGES_JSON:[{"file":"Datei.swift","action":"modify","content":"voller Dateiinhalt"}]

Bei reinen Fragen ohne Code-Änderung: Antworte normal auf Deutsch.
${context ? 'Zusätzlicher Kontext: ' + context : ''}`

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        systemInstruction: { parts: [{ text: systemPrompt }] },
        generationConfig: { temperature: 0.3, maxOutputTokens: 8192 }
      })
    }
  )

  const data = await res.json()
  const fullText: string = data.candidates?.[0]?.content?.parts?.[0]?.text ?? 'Keine Antwort erhalten.'

  // Extract CODE_CHANGES_JSON marker
  const marker = 'CODE_CHANGES_JSON:'
  const markerIdx = fullText.indexOf(marker)
  let codeChanges: CodeChange[] = []
  let responseText = fullText

  if (markerIdx !== -1) {
    try {
      const jsonStr = fullText.substring(markerIdx + marker.length).trim()
      codeChanges = JSON.parse(jsonStr)
      responseText = fullText.substring(0, markerIdx).trim()
    } catch { /* ignore parse error */ }
  }

  return { text: responseText, codeChanges }
}

async function commitToGitHub(changes: CodeChange[], message: string): Promise<string | null> {
  try {
    const gh = (path: string, opts?: RequestInit) =>
      fetch(`https://api.github.com/repos/${GITHUB_REPO}${path}`, {
        ...opts,
        headers: {
          Authorization: `Bearer ${GITHUB_TOKEN}`,
          Accept: 'application/vnd.github+json',
          'Content-Type': 'application/json',
          ...(opts?.headers ?? {})
        }
      })

    // Get base SHA
    const refData = await (await gh('/git/ref/heads/main')).json()
    const baseSHA: string = refData.object?.sha
    if (!baseSHA) throw new Error('Could not get base commit SHA')

    // Create blobs
    const treeItems = await Promise.all(changes.map(async (c) => {
      const blob = await (await gh('/git/blobs', {
        method: 'POST',
        body: JSON.stringify({ content: c.content, encoding: 'utf-8' })
      })).json()
      return { path: c.file, mode: '100644', type: 'blob', sha: blob.sha }
    }))

    // Create tree
    const tree = await (await gh('/git/trees', {
      method: 'POST',
      body: JSON.stringify({ base_tree: baseSHA, tree: treeItems })
    })).json()

    // Create commit
    const commitMsg = `🤖 KI-Agent: ${message.substring(0, 72)}`
    const commit = await (await gh('/git/commits', {
      method: 'POST',
      body: JSON.stringify({ message: commitMsg, tree: tree.sha, parents: [baseSHA] })
    })).json()

    // Update main ref
    await gh('/git/refs/heads/main', {
      method: 'PATCH',
      body: JSON.stringify({ sha: commit.sha })
    })

    console.log('Committed:', commit.sha)
    return commit.sha as string
  } catch (e) {
    console.error('GitHub commit failed:', e)
    return null
  }
}
