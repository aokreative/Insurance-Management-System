import { Router, type IRouter } from "express";
import healthRouter from "./health";
import agencyRouter from "./agency";

const router: IRouter = Router();

router.use(healthRouter);
router.use(agencyRouter);

export default router;
