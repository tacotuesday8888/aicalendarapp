import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  RulesTestEnvironment
} from "@firebase/rules-unit-testing";
import type firebase from "firebase/compat/app";
import "firebase/compat/firestore";
import "firebase/compat/storage";

const projectID = process.env.FIREBASE_RULES_TEST_PROJECT_ID?.trim() || "demo-aicalendarapp";
const bucketURL = `gs://${projectID}.appspot.com`;
const firestoreRulesPath = resolve(__dirname, "../../firestore/firestore.rules");
const storageRulesPath = resolve(__dirname, "../../storage/storage.rules");
const maxUploadBytes = 10 * 1024 * 1024;

const clientWritableCollections = [
  "onboarding",
  "goals",
  "plannerBlocks",
  "courses",
  "assignments",
  "habits",
  "studySessions",
  "checkIns",
  "vibeChecks",
  "reminderRules"
];

const serverOwnedCollections = [
  "assistantThreads",
  "goalPlans",
  "imports",
  "subscriptions",
  "aiUsageLogs",
  "aiUsage",
  "aiUsageDaily",
  "aiDrafts",
  "assistantDraftArtifacts"
];

type RulesTestCase = {
  name: string;
  run: (testEnv: RulesTestEnvironment) => Promise<void>;
};

const tests: RulesTestCase[] = [
  {
    name: "Firestore requires matching owner for user documents",
    run: async (testEnv) => {
      const anonymousDB = testEnv.unauthenticatedContext().firestore();
      const aliceDB = testEnv.authenticatedContext("alice").firestore();
      const bobDB = testEnv.authenticatedContext("bob").firestore();

      await assertFails(anonymousDB.doc("users/alice").get());
      await assertFails(anonymousDB.doc("users/alice").set({ name: "Anonymous" }));

      await assertSucceeds(aliceDB.doc("users/alice").set({ name: "Alice" }));
      const snapshot = await assertSucceeds(aliceDB.doc("users/alice").get());
      assert.equal(snapshot.get("name"), "Alice");

      await assertFails(bobDB.doc("users/alice").get());
      await assertFails(bobDB.doc("users/alice").set({ name: "Bob" }));
    }
  },
  {
    name: "Firestore allows owners to manage client-writable collections",
    run: async (testEnv) => {
      const aliceDB = testEnv.authenticatedContext("alice").firestore();

      for (const collection of clientWritableCollections) {
        const ref = aliceDB.doc(`users/alice/${collection}/doc-1`);
        await assertSucceeds(ref.set({ title: collection, done: false }));
        await assertSucceeds(ref.update({ done: true }));
        await assertSucceeds(ref.delete());
      }
    }
  },
  {
    name: "Firestore blocks cross-user reads and writes",
    run: async (testEnv) => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().doc("users/alice/goals/goal-1").set({ title: "Alice goal" });
      });

      const bobDB = testEnv.authenticatedContext("bob").firestore();
      await assertFails(bobDB.doc("users/alice/goals/goal-1").get());
      await assertFails(bobDB.doc("users/alice/goals/goal-1").set({ title: "Bob edit" }));
    }
  },
  {
    name: "Firestore keeps backend-owned collections read-only to clients",
    run: async (testEnv) => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const adminDB = context.firestore();
        for (const collection of serverOwnedCollections) {
          await adminDB.doc(`users/alice/${collection}/server-doc`).set({ source: "server" });
        }
      });

      const aliceDB = testEnv.authenticatedContext("alice").firestore();

      for (const collection of serverOwnedCollections) {
        const ref = aliceDB.doc(`users/alice/${collection}/server-doc`);
        const snapshot = await assertSucceeds(ref.get());
        assert.equal(snapshot.get("source"), "server");
        await assertFails(ref.set({ source: "client" }));
        await assertFails(ref.update({ source: "client" }));
        await assertFails(ref.delete());
      }
    }
  },
  {
    name: "Firestore blocks unknown direct user subcollections",
    run: async (testEnv) => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().doc("users/alice/customReadOnly/doc-1").set({ source: "server" });
      });

      const aliceDB = testEnv.authenticatedContext("alice").firestore();
      await assertFails(aliceDB.doc("users/alice/customReadOnly/doc-1").get());
      await assertFails(aliceDB.doc("users/alice/customReadOnly/doc-1").set({ source: "client" }));
    }
  },
  {
    name: "Firestore denies nested paths below user subcollection documents",
    run: async (testEnv) => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().doc("users/alice/goals/goal-1/comments/comment-1").set({ body: "Nested" });
      });

      const aliceDB = testEnv.authenticatedContext("alice").firestore();
      await assertFails(aliceDB.doc("users/alice/goals/goal-1/comments/comment-1").get());
      await assertFails(aliceDB.doc("users/alice/goals/goal-1/comments/comment-1").set({ body: "Client" }));
    }
  },
  {
    name: "Storage requires matching owner for reads and writes",
    run: async (testEnv) => {
      const path = "users/alice/imports/syllabus.txt";

      await testEnv.withSecurityRulesDisabled(async (context) => {
        await upload(context.storage(bucketURL).ref(path), bytes(12), "text/plain");
      });

      const anonymousStorage = testEnv.unauthenticatedContext().storage(bucketURL);
      const aliceStorage = testEnv.authenticatedContext("alice").storage(bucketURL);
      const bobStorage = testEnv.authenticatedContext("bob").storage(bucketURL);

      await assertFails(anonymousStorage.ref(path).getMetadata());
      await assertFails(upload(anonymousStorage.ref("users/alice/imports/anon.txt"), bytes(8), "text/plain"));

      await assertSucceeds(aliceStorage.ref(path).getMetadata());
      await assertSucceeds(upload(aliceStorage.ref("users/alice/imports/owned.txt"), bytes(8), "text/plain"));

      await assertFails(bobStorage.ref(path).getMetadata());
      await assertFails(upload(bobStorage.ref(path), bytes(8), "text/plain"));
    }
  },
  {
    name: "Storage allows expected upload content types",
    run: async (testEnv) => {
      const aliceStorage = testEnv.authenticatedContext("alice").storage(bucketURL);
      const allowedTypes = ["text/plain", "application/pdf", "application/octet-stream", "image/png"];

      for (const contentType of allowedTypes) {
        const safeName = contentType.replace("/", "-");
        await assertSucceeds(
          upload(aliceStorage.ref(`users/alice/imports/${safeName}`), bytes(16), contentType)
        );
      }
    }
  },
  {
    name: "Storage denies unsupported media upload content types",
    run: async (testEnv) => {
      const aliceStorage = testEnv.authenticatedContext("alice").storage(bucketURL);
      const deniedTypes = ["video/mp4", "audio/mpeg"];

      for (const contentType of deniedTypes) {
        const safeName = contentType.replace("/", "-");
        await assertFails(
          upload(aliceStorage.ref(`users/alice/imports/${safeName}`), bytes(16), contentType)
        );
      }
    }
  },
  {
    name: "Storage enforces the upload size boundary",
    run: async (testEnv) => {
      const aliceStorage = testEnv.authenticatedContext("alice").storage(bucketURL);

      await assertSucceeds(
        upload(aliceStorage.ref("users/alice/imports/under-limit.bin"), bytes(maxUploadBytes - 1), "application/pdf")
      );
      await assertFails(
        upload(aliceStorage.ref("users/alice/imports/at-limit.bin"), bytes(maxUploadBytes), "application/pdf")
      );
    }
  },
  {
    name: "Storage allows owner deletes for app cleanup",
    run: async (testEnv) => {
      const path = "users/alice/study-sessions/attachment.txt";

      await testEnv.withSecurityRulesDisabled(async (context) => {
        await upload(context.storage(bucketURL).ref(path), bytes(16), "text/plain");
      });

      const aliceStorage = testEnv.authenticatedContext("alice").storage(bucketURL);
      const bobStorage = testEnv.authenticatedContext("bob").storage(bucketURL);

      await assertFails(bobStorage.ref(path).delete());
      await assertSucceeds(aliceStorage.ref(path).delete());
    }
  },
  {
    name: "Storage denies writes outside user-owned prefixes",
    run: async (testEnv) => {
      const aliceStorage = testEnv.authenticatedContext("alice").storage(bucketURL);

      await assertFails(upload(aliceStorage.ref("public/imports/file.txt"), bytes(8), "text/plain"));
    }
  }
];

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: projectID,
    firestore: {
      rules: readFileSync(firestoreRulesPath, "utf8")
    },
    storage: {
      rules: readFileSync(storageRulesPath, "utf8")
    }
  });

  try {
    for (const test of tests) {
      await testEnv.clearFirestore();
      await testEnv.clearStorage();
      await test.run(testEnv);
      console.log(`PASS ${test.name}`);
    }
  } finally {
    await testEnv.cleanup();
  }

  console.log(`Firebase rules behavior tests passed for ${tests.length} cases.`);
}

function bytes(size: number): Uint8Array {
  return new Uint8Array(size);
}

function upload(ref: firebase.storage.Reference, data: Uint8Array, contentType: string): Promise<unknown> {
  return new Promise((resolveUpload, rejectUpload) => {
    ref.put(data, { contentType }).then(resolveUpload, rejectUpload);
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
