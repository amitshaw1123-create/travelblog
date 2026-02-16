import os
import anthropic


STYLE_DESCRIPTIONS = {
    "adventurous": "exciting, energetic, and inspiring — making readers want to pack their bags immediately",
    "informative": "detailed, helpful, and practical — full of useful tips and factual information",
    "poetic":      "lyrical, atmospheric, and evocative — painting vivid pictures with words",
}

SYSTEM_PROMPT = (
    "You are an expert travel writer for WanderLog, a personal travel blog. "
    "You write in first-person, immersive prose that transports readers to the destination. "
    "Your writing is warm, authentic, and personal."
)


def generate_post_draft(destination: str, highlights: list, style: str = "adventurous") -> dict:
    """
    Generate a travel blog post draft using Claude.

    Args:
        destination: The travel destination (e.g. "Kyoto, Japan")
        highlights:  List of key points / experiences to weave into the post
        style:       One of 'adventurous', 'informative', 'poetic'

    Returns:
        dict with keys 'title' (str) and 'content' (str)

    Raises:
        ValueError: if ANTHROPIC_API_KEY is not set
        RuntimeError: if the API call fails or the response cannot be parsed
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError(
            "ANTHROPIC_API_KEY environment variable is not set. "
            "Add it to your .env file or environment before using the AI writer."
        )

    style_desc = STYLE_DESCRIPTIONS.get(style, STYLE_DESCRIPTIONS["adventurous"])
    highlights_text = "\n".join(f"- {h}" for h in highlights if h.strip()) or "- No specific highlights provided"

    prompt = f"""Write a travel blog post for the WanderLog travel blog.

Destination: {destination}

Key highlights and experiences to cover:
{highlights_text}

Writing style: {style_desc}

Requirements:
- Write an engaging, compelling title (no more than 10 words)
- Write the full blog post content (400–600 words)
- Use natural paragraphs separated by blank lines
- Do NOT use markdown headers, bullet points, or bold text in the content — prose only
- The first paragraph must hook the reader immediately
- Weave in all key highlights naturally throughout the post
- End with an inspiring closing paragraph

Return your response in this EXACT format (keep the separator line):

TITLE: [your title here]
---
CONTENT:
[your blog post content here]"""

    client = anthropic.Anthropic(api_key=api_key)

    message = client.messages.create(
        model="claude-sonnet-4-5-20250929",
        max_tokens=1500,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": prompt}],
    )

    response_text = message.content[0].text.strip()
    return _parse_response(response_text, destination)


def _parse_response(text: str, destination: str) -> dict:
    """Parse Claude's structured response into title and content."""
    title = ""
    content = ""

    if "TITLE:" in text and "CONTENT:" in text:
        # Split on the --- separator
        parts = text.split("---", 1)
        title_section = parts[0].strip()
        content_section = parts[1].strip() if len(parts) > 1 else text

        title = title_section.replace("TITLE:", "").strip()
        content = content_section.replace("CONTENT:", "").strip()
    else:
        # Graceful fallback: treat first line as title, rest as content
        lines = text.strip().splitlines()
        title = lines[0].strip().lstrip("#").strip()
        content = "\n".join(lines[1:]).strip()

    if not title:
        title = f"My Journey to {destination}"

    if not content:
        raise RuntimeError("Claude returned an empty content block. Please try again.")

    return {"title": title, "content": content}
