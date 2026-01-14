interface Env {
  ENVIRONMENT: string;
  LLM_PROVIDER?: string;
  RECIPE_NORMALIZER_MODEL?: string;
  RECIPES_KV: KVNamespace;
  COMMON_FOOD_IMAGES: R2Bucket;
}

const DEFAULT_LLM_PROVIDER = "openai";
const DEFAULT_NORMALIZER_MODEL = "gpt-4o-mini";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.startsWith("/ingredients/")) {
      return handleIngredientImage(request, env, ctx);
    }

    if (url.pathname === "/config") {
      return new Response(
        JSON.stringify({
          environment: env.ENVIRONMENT,
          llmProvider: env.LLM_PROVIDER ?? DEFAULT_LLM_PROVIDER,
          recipeModel: env.RECIPE_NORMALIZER_MODEL ?? DEFAULT_NORMALIZER_MODEL,
        }),
        { headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Cooking Assistant Worker is online.", {
      headers: { "content-type": "text/plain" },
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
