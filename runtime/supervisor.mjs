import { spawn } from 'node:child_process';
import path from 'node:path';

const projectDirectory=path.resolve(import.meta.dirname,'..');
const children=[
  spawn(process.execPath,['runtime/api.mjs'],{cwd:projectDirectory,env:process.env,stdio:'inherit'}),
  spawn('ruby',['bin/photo_server'],{cwd:projectDirectory,env:process.env,stdio:'inherit'}),
];
let stopping=false;
const closed=children.map((child)=>new Promise((resolve)=>child.once('close',(code,signal)=>resolve({code,signal}))));

async function stop(signal,exitCode){
  if(stopping)return;
  stopping=true;
  for(const child of children){
    if(child.exitCode===null&&child.signalCode===null)child.kill(signal);
  }
  await Promise.all(closed);
  process.exit(exitCode);
}

for(const child of children){
  child.once('error',(error)=>{
    console.error(error.message);
    void stop('SIGTERM',1);
  });
  child.once('exit',(code,signal)=>{
    if(!stopping){
      console.error(`Photo runtime child exited unexpectedly (code=${code}, signal=${signal}).`);
      void stop('SIGTERM',code||1);
    }
  });
}
process.once('SIGINT',()=>void stop('SIGTERM',130));
process.once('SIGTERM',()=>void stop('SIGTERM',0));
