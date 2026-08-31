<?php

namespace OPNsense\AmneziaWG;

class GeneralController extends PageControllerBase
{
    public function indexAction()
    {
        $this->prepareView('general');
    }
}
