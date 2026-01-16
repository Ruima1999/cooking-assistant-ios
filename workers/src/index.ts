interface Env {
  ENVIRONMENT: string;
  LLM_PROVIDER?: string;
  RECIPE_NORMALIZER_MODEL?: string;
  LLM_API_KEY?: string;
  RECIPES_KV: KVNamespace;
  COMMON_FOOD_IMAGES: R2Bucket;
}

const DEFAULT_LLM_PROVIDER = "openai";
const DEFAULT_NORMALIZER_MODEL = "gpt-4o-mini";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(),
      });
    }

    if (url.pathname.startsWith("/ingredients/")) {
      return handleIngredientImage(request, env, ctx);
    }

    if (url.pathname === "/qa" && request.method === "POST") {
      return handleQuestion(request, env);
    }

    if (url.pathname === "/config") {
      return jsonResponse(
        JSON.stringify({
          environment: env.ENVIRONMENT,
          llmProvider: env.LLM_PROVIDER ?? DEFAULT_LLM_PROVIDER,
          recipeModel: env.RECIPE_NORMALIZER_MODEL ?? DEFAULT_NORMALIZER_MODEL,
        })
      );
    }

    return new Response("Cooking Assistant Worker is online.", {
      headers: corsHeaders({ "content-type": "text/plain" }),
    });
  },
};

async function handleIngredientImage(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  const url = new URL(request.url);
  const slug = url.pathname.replace("/ingredients/", "").toLowerCase();

  if (!slug) {
    return new Response("Ingredient not specified.", { status: 400 });
  }

  const cacheKey = new Request(url.toString(), request);
  const cached = await caches.default.match(cacheKey);
  if (cached) {
    return cached;
  }

  const object = await env.COMMON_FOOD_IMAGES.get(slug);
  if (!object) {
    return new Response("Image not found.", { status: 404 });
  }

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("content-type", object.httpMetadata?.contentType ?? "image/jpeg");
  headers.set("cache-control", "public, max-age=86400");

  const response = new Response(object.body, { headers });
  ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
  return response;
}

async function handleQuestion(request: Request, env: Env): Promise<Response> {
  if ((env.LLM_PROVIDER ?? DEFAULT_LLM_PROVIDER) !== "openai") {
    return jsonResponse(
      JSON.stringify({ error: "Only OpenAI is supported right now." }),
      400
    );
  }

  if (!env.LLM_API_KEY) {
    return jsonResponse(
      JSON.stringify({ error: "Missing LLM_API_KEY." }),
      500
    );
  }

  const payload = (await request.json()) as {
    question?: string;
    context?: string | null;
  };

  if (!payload.question) {
    return jsonResponse(JSON.stringify({ error: "Missing question." }), 400);
  }

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.LLM_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: env.RECIPE_NORMALIZER_MODEL ?? DEFAULT_NORMALIZER_MODEL,
      temperature: 0.2,
      messages: [
        {
          role: "system",
          content:
            "You are a concise cooking assistant. Answer conversion and measurement questions clearly in one or two sentences.",
        },
        {
          role: "user",
          content: payload.context
            ? `Recipe context: ${payload.context}\nQuestion: ${payload.question}`
            : payload.question,
        },
      ],
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    return jsonResponse(
      JSON.stringify({ error: `LLM error: ${errorText}` }),
      502
    );
  }

  const data = (await response.json()) as {
    choices?: { message?: { content?: string } }[];
  };
  const answer = data.choices?.[0]?.message?.content?.trim();

  if (!answer) {
    return jsonResponse(JSON.stringify({ error: "No answer returned." }), 502);
  }

  return jsonResponse(JSON.stringify({ answer }));
}

function jsonResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: corsHeaders({ "content-type": "application/json" }),
  });
}

function corsHeaders(extra: Record<string, string> = {}): Headers {
  return new Headers({
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type,authorization",
    ...extra,
  });
}
