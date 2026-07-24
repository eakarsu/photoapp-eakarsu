import http from 'node:http';
import crypto from 'node:crypto';
import { literal, persist, query } from './db.mjs';

const port=Number(process.env.BACKEND_PORT);
const frontendOrigin=`http://127.0.0.1:${process.env.FRONTEND_PORT}`;
const selectedEndpoint=String(process.env.RUNTIME_AI_ENDPOINT||'');
const feature=String(process.env.RUNTIME_AI_FEATURE||'application-assistant');
const project=String(process.env.RUNTIME_PROJECT_NAME||'Application');
const systemPrompt=String(process.env.RUNTIME_AI_SYSTEM_PROMPT||'Provide a concise, practical, evidence-aware answer for this application workflow.');
const json=(res,status,body)=>{res.writeHead(status,{'Content-Type':'application/json','Access-Control-Allow-Origin':frontendOrigin,'Access-Control-Allow-Headers':'Authorization, Content-Type'});res.end(JSON.stringify(body));};
const readBody=req=>new Promise((resolve,reject)=>{let value='';req.on('data',chunk=>{value+=chunk;if(value.length>1_000_000)reject(new Error('request too large'));});req.on('end',()=>{try{resolve(value?JSON.parse(value):{});}catch(error){reject(error);}});req.on('error',reject);});
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const cachedUsers=new Map();
const runtimeSessions=new Map();
const initialUsers=query(`SELECT id,email,password_hash,display_name,role FROM runtime_app_users WHERE active=TRUE`,{rows:true});
for(const row of initialUsers?initialUsers.split('\n'):[]){const [id,email,passwordHash,displayName,role]=row.split('\t');cachedUsers.set(email,{id,email,passwordHash,displayName,role});}
function verify(password,stored){const [kind,salt,digest]=String(stored).split('$');if(kind!=='scrypt'||!salt||!digest)return false;const candidate=crypto.scryptSync(password,salt,32);const expected=Buffer.from(digest,'hex');return candidate.length===expected.length&&crypto.timingSafeEqual(candidate,expected);}
function actor(req){const token=String(req.headers.authorization||'').replace(/^Bearer\s+/i,'');if(!token)return null;const cached=runtimeSessions.get(token);if(cached&&cached.expiresAt>Date.now())return cached.user;const row=query(`SELECT u.id,u.email,u.display_name,u.role FROM runtime_app_sessions s JOIN runtime_app_users u ON u.id=s.user_id WHERE s.token_hash=${literal(sha(token))} AND s.expires_at>NOW() AND u.active=TRUE LIMIT 1`,{rows:true});if(!row)return null;const [id,email,displayName,role]=row.split('\t');return{id,email,displayName,role};}
const server=http.createServer(async(req,res)=>{
  if(req.method==='OPTIONS'){res.writeHead(204,{'Access-Control-Allow-Origin':frontendOrigin,'Access-Control-Allow-Headers':'Authorization, Content-Type','Access-Control-Allow-Methods':'GET,POST,OPTIONS'});return res.end();}
  const url=new URL(req.url||'/',`http://127.0.0.1:${port}`);
  try{
    if(req.method==='GET'&&url.pathname==='/api/health')return json(res,200,{status:'ok',project});
    if(req.method==='POST'&&url.pathname==='/api/auth/login'){
      const body=await readBody(req);const email=String(body.email||'').trim().toLowerCase();const password=String(body.password||'');
      const record=cachedUsers.get(email);if(!record||!verify(password,record.passwordHash))return json(res,401,{error:'Invalid credentials'});
      const {id,email:userEmail,displayName,role}=record;const token=crypto.randomBytes(32).toString('hex');const user={id,email:userEmail,displayName,role};
      runtimeSessions.set(token,{user,expiresAt:Date.now()+86_400_000});
      persist(`INSERT INTO runtime_app_sessions(token_hash,user_id,expires_at) VALUES(${literal(sha(token))},${literal(id)}::uuid,NOW()+INTERVAL '24 hours')`).catch(error=>console.error(`session persistence: ${error.message}`));
      return json(res,200,{token,user:{id,email:userEmail,name:displayName,role}});
    }
    if(req.method==='GET'&&url.pathname==='/api/auth/me'){const user=actor(req);return user?json(res,200,{user}):json(res,401,{error:'Authentication required'});}
    if(req.method==='GET'&&url.pathname==='/api/ai/history'){
      const user=actor(req);if(!user)return json(res,401,{error:'Authentication required'});
      const rows=query(`SELECT json_build_object('id',id,'feature',feature,'input',input,'output',output,'model',model,'providerReceipt',provider_receipt,'createdAt',created_at)::text FROM runtime_ai_interactions WHERE user_id=${literal(user.id)}::uuid ORDER BY created_at DESC LIMIT 50`,{rows:true});
      return json(res,200,{history:rows?rows.split('\n').map(JSON.parse):[]});
    }
    if(req.method==='POST'&&url.pathname===selectedEndpoint){
      const user=actor(req);if(!user)return json(res,401,{error:'Authentication required'});
      const body=await readBody(req);const prompt=String(body.prompt||body.question||body.message||body.context||'').trim();if(!prompt)return json(res,400,{error:'prompt is required'});
      const base=String(process.env.OPENROUTER_BASE_URL||'').replace(/\/+$/,'');const model=String(process.env.OPENROUTER_MODEL||'').trim();const key=String(process.env.OPENROUTER_API_KEY||'').trim();
      if(base!=='https://openrouter.ai/api/v1'||!model||!key)throw new Error('Exact OpenRouter configuration is required');
      const response=await fetch(`${base}/chat/completions`,{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json','X-Title':project},body:JSON.stringify({model,messages:[{role:'system',content:systemPrompt},{role:'user',content:prompt}],max_tokens:650})});
      if(!response.ok)throw new Error(`OpenRouter API error (${response.status})`);
      const provider=await response.json();const content=String(provider.choices?.[0]?.message?.content||'').trim();if(!content)throw new Error('OpenRouter returned an empty response');
      const providerReceipt={requestId:String(provider.id||''),provider:String(provider.provider||'openrouter'),upstreamModel:String(provider.model||model),created:Number(provider.created||0)};
      if(!providerReceipt.requestId)throw new Error('OpenRouter provider receipt is missing');
      const saved=query(`INSERT INTO runtime_ai_interactions(user_id,feature,input,output,model,provider_receipt) VALUES(${literal(user.id)}::uuid,${literal(feature)},${literal(JSON.stringify(body))}::jsonb,${literal(JSON.stringify({content}))}::jsonb,${literal(model)},${literal(JSON.stringify(providerReceipt))}::jsonb) RETURNING id`,{rows:true});
      return json(res,200,{content,model,providerReceipt,interactionId:Number(saved),feature});
    }
    return json(res,404,{error:'Not found'});
  }catch(error){console.error(error.message);return json(res,500,{error:'Internal service error'});}
});
server.listen(port,'127.0.0.1',()=>console.log(`${project} runtime API listening on ${port}`));
