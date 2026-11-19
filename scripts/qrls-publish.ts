/**
 * 用 QRls 把已签名的 QLaunch 安装包发到 R2（主源），并可选同步到 GitHub。
 * Sparkle 签名与 delta 仍由本仓库 generate_appcast 生成，这里只负责上传和改写 enclosure URL。
 */
import { existsSync, readFileSync } from "node:fs";
import { basename } from "node:path";

export interface IFileInput {
  data: string;
  name: string;
  edSignature?: string;
  deltaFromVersion?: string;
}

export interface IQRlsVersionResult {
  version: string;
  buildVersion?: string;
  sparkle?: {
    feedUrl?: string;
  };
  [key: string]: unknown;
}

interface ParsedSparkleItem {
  buildVersion?: string;
  mainFile: {
    name: string;
    url?: string;
    sparkle?: {
      edSignature?: string;
    };
  };
  deltaFiles?: Array<{
    name: string;
    url?: string;
    deltaFromVersion?: string;
    sparkle?: {
      edSignature?: string;
      deltaFromVersion?: string;
    };
  }>;
}

let qrlsModuleCache: {
  parseSparkleAppcast?: (xml: string) => ParsedSparkleItem[];
  qrls?: (options: unknown) => Promise<IQRlsVersionResult>;
} | null | undefined = undefined;

async function getQrlsModule() {
  if (qrlsModuleCache !== undefined) return qrlsModuleCache;
  try {
    // @ts-ignore
    qrlsModuleCache = await import("qrls");
  } catch {
    qrlsModuleCache = null;
  }
  return qrlsModuleCache;
}

function fallbackParseSparkleAppcast(xml: string): ParsedSparkleItem[] {
  const items: ParsedSparkleItem[] = [];
  const itemMatches = xml.matchAll(/<item>([\s\S]*?)<\/item>/g);
  for (const match of itemMatches) {
    const itemXml = match[1];
    const deltasMatch = itemXml.match(/<sparkle:deltas>([\s\S]*?)<\/sparkle:deltas>/);
    const deltasXml = deltasMatch ? deltasMatch[1] : "";
    const mainXml = itemXml.replace(/<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/g, "");
    const mainEnclosure = mainXml.match(/<enclosure\s+([^>]+?)\/?>/);
    if (!mainEnclosure) continue;

    const getAttr = (attrs: string, name: string) => {
      const m = attrs.match(new RegExp(`${name}="([^"]*)"`));
      return m ? m[1] : undefined;
    };

    const mainAttrs = mainEnclosure[1];
    const buildVersion = getAttr(mainAttrs, "sparkle:version");
    const mainUrl = getAttr(mainAttrs, "url");
    const mainSig = getAttr(mainAttrs, "sparkle:edSignature");
    const mainName = mainUrl ? basename(mainUrl) : "";

    const deltaFiles: NonNullable<ParsedSparkleItem["deltaFiles"]> = [];
    if (deltasXml) {
      for (const dMatch of deltasXml.matchAll(/<enclosure\s+([^>]+?)\/?>/g)) {
        const dAttrs = dMatch[1];
        const dUrl = getAttr(dAttrs, "url");
        const dSig = getAttr(dAttrs, "sparkle:edSignature");
        const deltaFrom = getAttr(dAttrs, "sparkle:deltaFrom");
        deltaFiles.push({
          name: dUrl ? basename(dUrl) : "",
          url: dUrl,
          deltaFromVersion: deltaFrom,
          sparkle: {
            edSignature: dSig,
            deltaFromVersion: deltaFrom,
          },
        });
      }
    }

    items.push({
      buildVersion,
      mainFile: {
        name: mainName,
        url: mainUrl,
        sparkle: {
          edSignature: mainSig,
        },
      },
      deltaFiles,
    });
  }
  return items;
}

/** R2 公开访问前缀，末尾不含斜杠。 */
export const R2_ONLINE_URL = (
  process.env.R2_ONLINE_URL ?? "https://download.qzrzz.com/qlaunch"
).replace(/\/+$/, "");

/** R2 存储桶名。凭据从环境变量或 ~/.config/qrls/qrls.config.json 读取。 */
export const R2_BUCKET = process.env.R2_BUCKET ?? "qzrzz-download";

/** R2 对象键前缀。 */
export const R2_PATH = process.env.R2_PATH ?? "qlaunch";

/** 默认仍把同一份订阅同步到 GitHub，方便旧版 App 读到新 feed。 */
export const PUBLISH_GITHUB = process.env.PUBLISH_GITHUB !== "0";

/**
 * 拼接 R2 公开下载地址
 * @param fileName 对象文件名
 */
export function r2PublicUrl(fileName: string): string {
  return `${R2_ONLINE_URL}/${fileName}`;
}

/** 建议写入 Info.plist SUFeedURL 的稳定订阅地址。 */
export const SPARKLE_FEED_URL = r2PublicUrl("appcast.xml");

/** 一次发布需要的本地产物路径。 */
export interface IQrlsPublishFiles {
  dmgPath: string;
  zipPath: string;
  notesPath: string;
  appcastPath: string;
  deltaPaths: string[];
}

/** 发布身份与渠道。 */
export interface IQrlsPublishInput extends IQrlsPublishFiles {
  name: string;
  version: string;
  build: string;
  repository: string;
  changelog?: string;
  force?: boolean;
  statePath?: string;
}

/**
 * 从本机 generate_appcast 产物里抽出当前 build 的 EdDSA 签名
 * @param appcastPath 本地 appcast.xml
 * @param build CURRENT_PROJECT_VERSION
 */
export function readSparkleSignatures(
  appcastPath: string,
  build: string,
): {
  zipSignature?: string;
  deltas: Array<{ name: string; edSignature?: string; deltaFromVersion?: string }>;
} {
  if (!existsSync(appcastPath)) {
    return { deltas: [] };
  }
  const parser = qrlsModuleCache?.parseSparkleAppcast ?? fallbackParseSparkleAppcast;
  const items = parser(readFileSync(appcastPath, "utf8"));
  const current = items.find((item) => item.buildVersion === build);
  if (!current) {
    return { deltas: [] };
  }
  return {
    zipSignature: current.mainFile.sparkle?.edSignature,
    deltas: (current.deltaFiles ?? []).map((delta) => ({
      name: delta.name,
      edSignature: delta.sparkle?.edSignature,
      deltaFromVersion: delta.deltaFromVersion ?? delta.sparkle?.deltaFromVersion,
    })),
  };
}

/**
 * 把 ZIP / 说明 / delta 编成 QRls 附件列表，并带上 Sparkle 签名
 * @param files 本地产物
 * @param build 当前构建号
 */
export function collectSparkleAttachments(
  files: IQrlsPublishFiles,
  build: string,
): IFileInput[] {
  const signatures = readSparkleSignatures(files.appcastPath, build);
  const attachments: IFileInput[] = [
    {
      data: files.zipPath,
      name: basename(files.zipPath),
      edSignature: signatures.zipSignature,
    },
  ];
  if (existsSync(files.notesPath)) {
    attachments.push({
      data: files.notesPath,
      name: basename(files.notesPath),
    });
  }

  const signatureByName = new Map(
    signatures.deltas.map((delta) => [delta.name, delta]),
  );
  for (const deltaPath of files.deltaPaths) {
    const name = basename(deltaPath);
    const signed = signatureByName.get(name);
    attachments.push({
      data: deltaPath,
      name,
      edSignature: signed?.edSignature,
      deltaFromVersion: signed?.deltaFromVersion,
    });
  }
  return attachments;
}

/**
 * 调用 QRls：主发 R2，可选同步 GitHub
 * @param input 版本与本地产物
 */
export async function publishWithQrls(
  input: IQrlsPublishInput,
): Promise<IQRlsVersionResult> {
  if (!existsSync(input.dmgPath) || !existsSync(input.zipPath)) {
    throw new Error("QRls 发布缺少已公证的 DMG 或 Sparkle ZIP");
  }

  const changelog =
    input.changelog ||
    (existsSync(input.notesPath) ? readFileSync(input.notesPath, "utf8") : "");

  const qrlsModule = await getQrlsModule();
  if (!qrlsModule?.qrls) {
    throw new Error("未找到 'qrls' 模块。如需发布到 R2，请先安装或链接 qrls。");
  }

  return qrlsModule.qrls({
    name: input.name,
    version: input.version,
    buildVersion: input.build,
    changelog,
    variants: {
      "macos-arm": {
        main: {
          data: input.dmgPath,
          name: basename(input.dmgPath),
        },
        files: collectSparkleAttachments(input, input.build),
      },
    },
    sparkle: {
      enabled: true,
      origin: "r2",
      publishFeedTo: PUBLISH_GITHUB ? ["r2", "github"] : ["r2"],
      enclosure: "zip",
      mergeExisting: true,
      existingAppcast: existsSync(input.appcastPath)
        ? readFileSync(input.appcastPath, "utf8")
        : undefined,
      maximumVersions: 10,
      title: `${input.name} Updates`,
      language: "zh-CN",
    },
    historyMax: 0,
    force: input.force === true,
    statePath: input.statePath,
    verbose: true,
    target: {
      r2: {
        onlineUrl: R2_ONLINE_URL,
        bucket: R2_BUCKET,
        path: R2_PATH,
      },
      ...(PUBLISH_GITHUB
        ? {
            github: {
              repo: input.repository,
            },
          }
        : {}),
    },
  });
}
