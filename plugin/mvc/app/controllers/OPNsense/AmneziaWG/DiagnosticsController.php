<?php

namespace OPNsense\AmneziaWG;

class DiagnosticsController extends PageControllerBase
{
    public function indexAction()
    {
        $this->prepareView('diagnostics');
    }
}
