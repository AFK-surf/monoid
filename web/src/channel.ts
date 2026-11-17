// Which channel the page is on, decided as it loads (one build serves both, so a build tried on the test channel is
// promoted unchanged): the test channel's page (app.youdid.wtf) is marked by stillfail-web-beta with
// <meta name="stillfail-beta" content="<the stable origin>"> (cloud/src/web.ts); the desktop app's beta build says so
// through its preload. Kept free of React and the core so the core's opener (core/client.ts) can use it too. Which
// product it is goes by its origin as the core's words do (client/i18n/brand.ts): monoid on monoid.build and
// monoid.zone (its test channel's), still.fail anywhere else.
import { branded, productOf, STILLFAIL, type Product } from "../../client/i18n/brand.ts";

/** The test channel's mark on this page, if any. */
const BETA_META = typeof document === "undefined" ? null : document.querySelector<HTMLMetaElement>('meta[name="stillfail-beta"]');

/** The product this page's origin is. */
export const PRODUCT: Product = productOf(typeof location === "undefined" ? "" : location.origin);

/** Whether this page is the test channel's web (app.youdid.wtf, app.monoid.zone). */
export const BETA = Boolean(BETA_META) || (typeof location !== "undefined" && (location.host === "app.youdid.wtf" || location.host === "app.monoid.zone"));

/** The name the product goes by here: on the test channel's web its own (still.fail's youdid.wtf, monoid's monoid.zone). */
export const NAME = BETA ? PRODUCT.test : PRODUCT.name;

/** The test channel's web host of this product. */
export const BETA_HOST = `app.${PRODUCT.test}`;

/** The catalog's words (which say still.fail) as this product says them: its name, its test channel's host. */
export const sayProduct = (text: string): string => (PRODUCT === STILLFAIL ? text : branded(text, PRODUCT).replaceAll("app.youdid.wtf", BETA_HOST));
