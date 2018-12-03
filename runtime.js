const CNako3 = require('nadesiko3/src/cnako3');
const fetch = require('node-fetch');
const fs = require('fs');

// https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html
const API = `http://${process.env.AWS_LAMBDA_RUNTIME_API}/2018-06-01`;

async function nextInvocation() {
  const next = await fetch(`${API}/runtime/invocation/next`);
  const requestId = next.headers.get('Lambda-Runtime-Aws-Request-Id');
  const eventData = await next.json();
  const context = {
    リクエストID: requestId,
    タイムアウト: parseInt(next.headers.get('Lambda-Runtime-Deadline-Ms'), 10),
    関数ARN: next.headers.get('Lambda-Runtime-Invoked-Function-Arn'),
    ロググループ名: process.env.AWS_LAMBDA_LOG_GROUP_NAME,
    ログストリーム名: process.env.AWS_LAMBDA_LOG_STREAM_NAME,
    関数名: process.env.AWS_LAMBDA_FUNCTION_NAME,
    関数バージョン: process.env.AWS_LAMBDA_FUNCTION_VERSION,
    関数メモリサイズ: parseInt(process.env.AWS_LAMBDA_FUNCTION_MEMORY_SIZE, 10),
  };
  return { requestId, eventData, context };
}

async function invocationResponse(requestId, response) {
  const body = typeof response === 'object' ? JSON.stringify(response) : response;
  await fetch(`${API}/runtime/invocation/${requestId}/response`, {
    method: 'post',
    body,
  });
}

async function invocationError(requestId, error) {
  body = JSON.stringify({ errorMessage: error.message, errorType: error.name });
  await fetch(`${API}/runtime/invocation/${requestId}/error`, {
    method: 'post',
    body,
  });
}

async function initializationError(error) {
  body = JSON.stringify({ errorMessage: error.message, errorType: error.name });
  await fetch(`${API}/runtime/init/error`, {
    method: 'post',
    body,
  });
}

async function initialize() {
  try {
    const compiler = new CNako3();
    compiler.addPlugin({
      'lambda関数実行残時間': { // @lambda関数を実行可能な残り時間をミリセカンドで返す // @らむだかんすうじっこうのこりじかん
        type: 'func',
        josi: [['の']],
        fn: (context) => {
          if (! 'タイムアウト' in context || typeof(context['タイムアウト']) !== 'number') {
            throw new Error('正しいコンテキストが指定されていません');
          }
          return new Date(context['タイムアウト']) - new Date();
        },
      },
    });
    const [fileName, methodName] = process.env._HANDLER.split('.');
    const code = fs.readFileSync(`./${fileName}.nako`, { encoding: 'utf-8'});
    compiler.runReset(code);
    const methods = compiler.__varslist[1];
    return methods[methodName];
  } catch (error) {
    try {
      await initializationError(error);
    } catch (reportError) {
      console.error(error);
    }
    console.error(error);
    process.exit(1);
  }
}

async function invoke(method) {
  const { requestId, eventData, context } = await nextInvocation();
  try {
    const response = method(eventData, context);
    await invocationResponse(requestId, response); 
  } catch (error) {
    console.error(error);
    try {
      invocationError(requestId, error);
    } catch (reportError) {
      console.error(error);
    }
  }
}

async function main() {
  const method = await initialize();
  while (true) {
    await invoke(method);
  }
}

main();
