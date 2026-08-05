import { Router, type IRouter } from "express";
import healthRouter from "./health";
import agencyRouter from "./agency";
import reportsRouter from "./reports";

const router: IRouter = Router();

router.use(healthRouter);
router.use(agencyRouter);
router.use(reportsRouter);

export default router;
